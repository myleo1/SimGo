#!/usr/bin/env python3
"""vCard → SimGo contacts.csv 一次性导入工具

用法：
    python3 vcard_to_csv.py 输入.vcf [输出.csv]
    python3 vcard_to_csv.py [--replace] 输入.vcf [输出.csv]

默认输出到 <脚本上级目录>/spool/contacts.csv（即 <部署目录>/spool/contacts.csv）。
默认追加合并已有文件（同名去重）；加 --replace 则全量覆盖。
号码规范化：同一联系人同时生成"原始号码"与"去掉 +86/0086 前缀"两行，提高匹配率。
"""
import argparse
import os
import re
import sys


def parse_vcard(path):
    """解析 vCard 文件，返回 [(name, [numbers...]), ...]，保持出现顺序。"""
    contacts = []
    current = None
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw_line in fh:
            line = raw_line.rstrip("\r\n")
            if not line:
                continue
            if line.upper().startswith("BEGIN:"):
                current = {"name": None, "numbers": []}
                continue
            if line.upper().startswith("END:"):
                if current is not None:
                    contacts.append(current)
                    current = None
                continue
            if current is None:
                continue
            key, _, value = line.partition(":")
            # vCard 属性可带参数，如 FN;CHARSET=UTF-8 或 TEL;TYPE=CELL
            attr = key.split(";", 1)[0].upper()
            if "." in attr:
                # 去掉 vCard 属性组前缀（Apple 系写法），如 item1.TEL → TEL
                attr = attr.split(".", 1)[1]
            params = key.split(";", 1)[1] if ";" in key else ""
            value = value.strip()
            if attr in ("FN", "N"):
                if current["name"] is None or attr == "FN":
                    # N 为 "姓;名" 结构（分号分隔），FN 为完整名
                    if attr == "FN":
                        current["name"] = value
                    elif attr == "N":
                        parts = [p.strip() for p in value.split(";")]
                        # 中文习惯：姓在前；西方习惯：姓(Given)在后
                        surname = parts[0].strip()
                        given = parts[1].strip() if len(parts) > 1 else ""
                        combined = (surname + given) if surname and given else value
                        current["name"] = combined
            elif attr == "TEL":
                params_up = params.upper()
                num = _clean_number(value)
                if num:
                    # TEL 与 TEL;TYPE=CELL 共用一个 list，CELL/VOICE 优先标记
                    rank = 0
                    if "CELL" in params_up or "VOICE" in params_up or "PREF" in params_up:
                        rank = 0
                    else:
                        rank = 1
                    current["numbers"].append((num, rank))
    return contacts


def _clean_number(value):
    num = re.sub(r"\D", "", value)
    return num


def normalize_numbers(num):
    """返回需要写入的行列表：原始号码 + 去掉+86前缀的真实手机号（1[3-9] 号段）。"""
    variants = []

    def is_cn_mobile(s):
        # 86 去掉后为 1[3-9] 开头的 11 位手机号（131-199）；排除 8610/8620 等非手机前缀
        return len(s) == 13 and s[2] == "1" and s[3] in "3456789"

    if num.startswith("86") and is_cn_mobile(num):
        variants.append(num[2:])
    if num.startswith("0086"):
        stripped = num[4:]
        variants.append(stripped)
        if is_cn_mobile(stripped):
            variants.append(stripped[2:])
    variants.append(num)
    # 去重保序
    seen = set()
    result = []
    for v in variants:
        if v not in seen:
            seen.add(v)
            result.append(v)
    return result


def main():
    parser = argparse.ArgumentParser(description="vCard → SimGo contacts.csv 导入工具")
    parser.add_argument("vcf", help="输入的 vCard 文件路径")
    parser.add_argument("csv", nargs="?", help="输出的 csv 路径（默认 <部署目录>/spool/contacts.csv）")
    parser.add_argument("--replace", action="store_true", help="全量覆盖原 csv（默认追加合并）")
    args = parser.parse_args()

    if not os.path.isfile(args.vcf):
        sys.exit(f"错误：找不到 vCard 文件 {args.vcf}")

    out_path = args.csv
    if not out_path:
        base = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
        out_path = os.path.join(base, "spool", "contacts.csv")

    contacts = parse_vcard(args.vcf)
    if not contacts:
        sys.exit("错误：vCard 中未解析到任何联系人")

    # 构造新数据行集合（号码,名字），包含 +86 规范化多行
    new_rows = {}
    for contact in contacts:
        name = contact["name"] if contact["name"] else "未知"
        # cell/voice/pref 号码排在前面（rank 小优先）
        for num, _rank in sorted(contact["numbers"], key=lambda x: x[1]):
            for variant in normalize_numbers(num):
                new_rows[variant] = name

    # 读取已有 csv（追加模式）
    existing_rows = {}
    header = "号码,名字"
    if os.path.isfile(out_path) and not args.replace:
        with open(out_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or line.startswith("号码,"):
                    continue
                num, _, name = line.partition(",")
                if num:
                    existing_rows[num] = name

    merged = dict(existing_rows)
    merged.update(new_rows)  # 新数据覆盖同名旧数据

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(header + "\n")
        for num in sorted(merged):
            name = merged[num].replace(",", "、")  # 名字含逗号会破坏 CSV 解析
            fh.write(f"{num},{name}\n")

    print(f"导入完成：{len(new_rows)} 条号码写入了 {out_path}（当前总计 {len(merged)} 条）")
    print(f"提示：该文件为运行时联系人映射，请勿提交到 Git 仓库。")


if __name__ == "__main__":
    main()