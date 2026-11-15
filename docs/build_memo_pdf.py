"""Renders docs/executive_memo.md -> docs/executive_memo.pdf (A4, must be <= 2 pages)."""
import pathlib, subprocess, markdown
D = pathlib.Path(__file__).resolve().parent
body = markdown.markdown((D/'executive_memo.md').read_text(), extensions=['tables'])
css = """@page{size:A4;margin:13mm 14mm}
body{font-family:Inter,Helvetica,Arial,sans-serif;font-size:9.4pt;line-height:1.36;color:#111}
h1{font-size:14pt;margin:0 0 4px} h2{font-size:10.8pt;margin:9px 0 3px;color:#1c5fae;border-bottom:1px solid #dde;padding-bottom:2px}
p{margin:3px 0} ul,ol{margin:3px 0;padding-left:17px} li{margin:1.5px 0}
table{border-collapse:collapse;width:100%;margin:4px 0;font-size:8.6pt} th,td{border:1px solid #d8d8d4;padding:2.5px 5px;text-align:left;vertical-align:top}
th{background:#f1f1ee}"""
html = f"<!DOCTYPE html><html><head><meta charset='utf-8'><style>{css}</style></head><body>{body}</body></html>"
(D/'_memo.html').write_text(html)
subprocess.run(['google-chrome','--headless','--no-sandbox','--disable-gpu','--no-pdf-header-footer',
                f'--print-to-pdf={D/"executive_memo.pdf"}', (D/'_memo.html').as_uri()], check=True, capture_output=True)
(D/'_memo.html').unlink()
print('executive_memo.pdf written')
