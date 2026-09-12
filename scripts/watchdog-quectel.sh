#!/bin/bash
# SimGo watchdog — EC20 driver state monitor & self-heal (host side)
#
# Polls "quectel show device state" through the container's asterisk CLI,
# classifies every possible driver State value and recovers anomalies by a
# light-to-heavy chain. See docs/DESIGN.md §18 for the design.
#
# Scheduled by setup.sh: */2 via crontab (tag "# SimGo-watchdog").
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIMGO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONTAINER="${SIMGO_CONTAINER:-simgo}"
LOG="${SIMGO_ROOT}/logs/watchdog-quectel.log"
STATE_DIR="${SIMGO_ROOT}/scripts/.watchdog-state"
LOCK_FILE="/tmp/simgo-watchdog.lock"

DEBOUNCE=${WATCHDOG_DEBOUNCE:-2}
COOLDOWN_SEC=${WATCHDOG_COOLDOWN_SEC:-1800}
DAILY_MAX=${WATCHDOG_DAILY_MAX:-5}
RECHECK_SLEEP=${WATCHDOG_RECHECK_SLEEP:-15}
NOTIFY_ENABLED=${WATCHDOG_NOTIFY:-yes}

log_msg() {
	local level="$1" dev="$2" msg="$3"
	printf '[%s] %-10s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$dev" "$level" "$msg" >>"$LOG"
}

# Run a read-only asterisk CLI command through the container.
# Returns the output on stdout; a nonzero rc means the query failed.
run_asterisk() {
	docker exec "${CONTAINER}" asterisk -rx "$1" 2>/dev/null
}

# Fetch the driver state line for a device. Empty output -> query failure.
fetch_state() {
	local dev="$1"
	run_asterisk "quectel show device state ${dev}" |
		sed -n 's/^[[:space:]]*State[[:space:]]*:[[:space:]]*\(.*\)$/\1/p' |
		head -n 1
}

# Classify a State value into: SKIP / FAULT_REG / FAULT_INIT / FAULT_LINK / OK
#
# State = 主体（pvt_state_base()）+ 可选尾缀。尾缀 Stop/Restart/Removal/Start scheduled
# 仅在 desired_state != current_state 时附加（chan_quectel.c:1676），表示驱动正处在
# 状态切换调度中（start/stop/restart 尚未落定），此时切换由驱动自己完成，watchdog 不得
# 干预，否则会与驱动自愈打架。因此首个分支 *scheduled* -> SKIP 是刻意设计，勿删。
# 实测（2026-09）：拔卡 -> "Not connected Start scheduled"（current=stop/desired=start）-> SKIP；
# 有卡在线未注册 -> "GSM not registered"（无尾缀，current=start/desired=start）-> FAULT_REG。
classify() {
	local text="$1"
	case "$text" in
		*"scheduled"*) echo "SKIP" ;;
		"Stopped")    echo "SKIP" ;;
		"GSM not registered") echo "FAULT_REG" ;;
		"Not initialized")    echo "FAULT_INIT" ;;
		"Not connected")      echo "FAULT_LINK" ;;
		*)            echo "OK" ;;
	esac
}

# Are there active calls? Empty/unknown output -> caller treats as "don't act".
active_call_count() {
	run_asterisk "core show channels count" |
		sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*active channel.*$/\1/p' |
		head -n 1
}

# --- state persistence (<dev>.state as key=value lines) ------------------------
state_read() {
	local file="$1" key="$2"
	local val=""
	[ -f "$file" ] || { echo ""; return 0; }
	val="$(sed -n "s/^${key}=//p" "$file" | head -n 1)"
	echo "${val:-}"
}

state_set() {
	local file="$1" key="$2" value="$3" tmp
	tmp="${file}.tmp"
	[ -f "$file" ] && sed "/^${key}=/d" "$file" >"$tmp"
	{
		[ -f "$tmp" ] && cat "$tmp"
		echo "${key}=${value}"
	} >"$file" 2>/dev/null
	rm -f "$tmp"
}

# --- notification ---------------------------------------------------------------
notify() {
	local dev="$1" title="$2" body="$3"
	[ "${NOTIFY_ENABLED}" = "yes" ] || return 0
	docker exec "${CONTAINER}" python3 /etc/asterisk/scripts/notify_alarm.py "${title}" "${body}" >/dev/null 2>&1 ||
		log_msg "WARN" "$dev" "notification send failed"
}

# --- recovery chains -------------------------------------------------------------
# Returns 0 when recovered, 1 when still faulty after the whole chain.
recheck_ok() {
	local dev="$1" text class
	text="$(fetch_state "$dev")"
	[ -n "$text" ] || return 1
	class="$(classify "$text")"
	[ "${class}" = "OK" ] || [ "${class}" = "SKIP" ]
}

recover_chain_a() {
	local dev="$1" cer gre cer_stat gre_stat
	cer="$(run_asterisk "quectel at ${dev} AT+CEREG?" 5000)"
	gre="$(run_asterisk "quectel at ${dev} AT+CREG?" 5000)"
	cer_stat="$(printf '%s' "${cer}" | grep -o '+CEREG: [0-9],[0-9]' | head -n 1 | cut -d, -f2)"
	gre_stat="$(printf '%s' "${gre}" | grep -o '+CREG: [0-9],[0-9]' | head -n 1 | cut -d, -f2)"
	log_msg "INFO" "$dev" "probe (sync, timeout 5s): CEREG=${cer_stat:-unknown} CREG=${gre_stat:-unknown}"
	log_msg "INFO" "$dev" "recovery chain A: quectel reset"
	run_asterisk "quectel reset ${dev}" >/dev/null
	sleep "${RECHECK_SLEEP}"
	if recheck_ok "$dev"; then return 0; fi
	log_msg "WARN" "$dev" "recovery chain A: still failing after reset, trying AT+CFUN=1,1"
	run_asterisk "quectel cmd ${dev} AT+CFUN=1,1" >/dev/null
	sleep "${RECHECK_SLEEP}"
	if recheck_ok "$dev"; then return 0; fi
	log_msg "ERROR" "$dev" "recovery chain A failed after CFUN"
	return 1
}

recover_chain_b() {
	local dev="$1"
	log_msg "INFO" "$dev" "recovery chain B: quectel reset"
	run_asterisk "quectel reset ${dev}" >/dev/null
	sleep "${RECHECK_SLEEP}"
	if recheck_ok "$dev"; then return 0; fi
	log_msg "ERROR" "$dev" "recovery chain B failed (do not issue CFUN for init failures)"
	return 1
}

recover_chain_c() {
	local dev="$1"
	log_msg "INFO" "$dev" "recovery chain C: quectel restart now"
	run_asterisk "quectel restart now ${dev}" >/dev/null
	sleep "${RECHECK_SLEEP}"
	if recheck_ok "$dev"; then return 0; fi
	log_msg "ERROR" "$dev" "recovery chain C failed (do not issue CFUN for link failures)"
	return 1
}

# --- per-device handling -----------------------------------------------------------
process_device() {
	local dev="$1"
	local sfile="${STATE_DIR}/${dev}.state"
	local today="$(date +%F)" now="$(date +%s)"
	local text class count fault cool_until actions last_date last_day notified_skip

	count="$(state_read "$sfile" count)"; [ -n "$count" ] || count=0
	fault="$(state_read "$sfile" fault)"
	cool_until="$(state_read "$sfile" cool_until)"; [ -n "$cool_until" ] || cool_until=0
	actions="$(state_read "$sfile" actions)"; [ -n "$actions" ] || actions=0
	last_date="$(state_read "$sfile" last_date)"

	# new day -> reset daily action counter
	if [ "${last_date}" != "${today}" ]; then
		actions=0
		state_set "$sfile" last_date "$today"
		state_set "$sfile" actions 0
	fi

	text="$(fetch_state "$dev")"
	if [ -z "$text" ]; then
		log_msg "WARN" "$dev" "state query failed (asterisk/container not reachable), skip"
		return 0
	fi
	class="$(classify "$text")"

	# Hands-off state with a "scheduled" suffix = driver is mid state-switch
	# (SIM pulled, manual stop/restart). Notify once; the flag is cleared as
	# soon as a non-switching state is seen again (another SIM inserted, etc.).
	if printf '%s' "${text}" | grep -q 'scheduled'; then
		local notified_skip
		notified_skip="$(state_read "$sfile" notified_skip)"
		if [ "${notified_skip}" != "1" ]; then
			log_msg "WARN" "$dev" "driver in mid-state switch (${text}); staying hands-off"
			notify "$dev" "SimGo 模块状态提示" "${dev} 检测到驱动处于状态切换中（${text}），疑似拔卡或手动操作。watchdog 已静默等待，插回 SIM 卡后会自动恢复。"
			state_set "$sfile" notified_skip 1
		fi
	elif [ "$(state_read "$sfile" notified_skip)" = "1" ]; then
		state_set "$sfile" notified_skip 0
	fi

	case "${class}" in
		SKIP)
			return 0
			;;
		OK)
			if [ "${count}" -ge "${DEBOUNCE}" ]; then
				log_msg "INFO" "$dev" "recovered (state: ${text})"
				notify "$dev" "SimGo 模块状态恢复" "${dev} 已恢复正常（${text}）"
			fi
			state_set "$sfile" fault ""
			state_set "$sfile" count 0
			state_set "$sfile" cool_until 0
			return 0
			;;
		FAULT_REG | FAULT_INIT | FAULT_LINK)
			: ;;
		*)
			log_msg "WARN" "$dev" "unknown state '${text}', treat as query failure"
			return 0
			;;
	esac

	# still failing while cooling down, or daily budget exhausted -> log only
	if [ "${now}" -lt "${cool_until}" ]; then
		log_msg "WARN" "$dev" "still ${text}, cooling down until $(date -d @${cool_until} '+%F %T' 2>/dev/null || echo ${cool_until})"
		return 0
	fi
	if [ "${actions}" -ge "${DAILY_MAX}" ]; then
		log_msg "ERROR" "$dev" "daily action limit reached (${DAILY_MAX}), waiting for manual intervention"
		[ "${count}" -eq "${DEBOUNCE}" ] && notify "$dev" "SimGo 模块持续异常" "${dev} 今日自愈已达上限，请人工排查"
		return 0
	fi

	count=$((count + 1))
	state_set "$sfile" fault "${class}"
	state_set "$sfile" count "${count}"

	if [ "${count}" -lt "${DEBOUNCE}" ]; then
		log_msg "WARN" "$dev" "state ${text} (${count}/2), waiting for debounce"
		return 0
	fi

	# call protection: never act while a call is in progress
	local active
	active="$(active_call_count)"
	if [ -z "$active" ] || [ "${active}" -gt 0 ]; then
		log_msg "WARN" "$dev" "state ${text} but ${active:-unresolved} active channel(s), defer (keep counter)"
		return 0
	fi

	log_msg "WARN" "$dev" "state ${text}, starting automatic recovery"
	notify "$dev" "SimGo 模块状态告警" "${dev} 状态异常（${text}），开始自动恢复"

	local ok
	ok=1
	case "${class}" in
		FAULT_REG)  recover_chain_a "$dev" ;;
		FAULT_INIT) recover_chain_b "$dev" ;;
		FAULT_LINK) recover_chain_c "$dev" ;;
	esac && ok=0

	if [ "${ok}" -eq 0 ]; then
		log_msg "INFO" "$dev" "automatic recovery succeeded"
		notify "$dev" "SimGo 模块状态恢复" "${dev} 已自动恢复"
		state_set "$sfile" fault ""
		state_set "$sfile" count 0
	else
		log_msg "ERROR" "$dev" "automatic recovery failed, manual intervention needed"
		notify "$dev" "SimGo 模块持续异常" "${dev} 自动恢复失败，请人工排查"
		state_set "$sfile" count 0
	fi
	state_set "$sfile" cool_until "$((now + COOLDOWN_SEC))"
	state_set "$sfile" actions "$((actions + 1))"
}

main() {
	mkdir -p "${LOG%/*}" "${STATE_DIR}"
	exec 9>"${LOCK_FILE}"
	flock -n 9 || exit 0

	local devlist i
	devlist="$(run_asterisk "quectel show devices" | grep -oE 'quectel[0-9]+' | sort -u || true)"
	if [ -z "${devlist}" ]; then
		log_msg "WARN" "all" "no devices listed by quectel show devices"
		return 0
	fi
	for i in ${devlist}; do
		process_device "$i"
	done
}

main "$@"