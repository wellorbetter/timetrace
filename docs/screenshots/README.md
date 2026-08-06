# 截图 Screenshots

README 使用相对路径引用截图，推送到 GitHub 后会自动渲染。

## 如何添加 / How to add

1. 截图（Win + Shift + S）并保存为 PNG，例如：
   - `docs/screenshots/dashboard.png` — 仪表盘（柱状图 / 饼图 / 汇总）
   - `docs/screenshots/journal.png` — 日记列表
   - `docs/screenshots/hourly.png` — 24h 时段分布
2. 在 `README.md` 的截图表格中按需增删引用：
   ```markdown
   ![仪表盘](docs/screenshots/dashboard.png)
   ```
3. 提交并推送：
   ```bash
   git add docs/screenshots
   git commit -m "docs: 添加截图"
   git push
   ```

## 建议 / Tips

- 分辨率建议 1280×800 左右，PNG 格式，单张尽量 < 1MB。
- 截图里如有隐私内容，先打码再上传。