# 第三方组件

墨览用到下面这些开源项目。除 Mermaid 外都通过 npm 在构建时取得，打包进 app 的页面资源里；它们间接依赖的库都是 MIT、BSD、ISC、PSF、Unlicense 这类宽松许可证，详见 `web/package-lock.json`。

| 组件 | 版本 | 许可证 |
|---|---|---|
| @vscode/markdown-it-katex | 1.1.2 | MIT |
| esbuild | 0.28.2 | MIT |
| highlight.js | 11.12.0 | BSD-3-Clause |
| js-yaml | 5.5.0 | MIT |
| katex | 0.19.1 | MIT |
| markdown-it | 15.0.3 | MIT |
| markdown-it-anchor | 10.0.0 | Unlicense |
| markdown-it-cjk-breaks | 2.0.1 | MIT |
| markdown-it-cjk-friendly | 3.0.0 | MIT |
| markdown-it-footnote | 4.0.0 | MIT |
| markdown-it-front-matter | 0.2.4 | MIT |
| markdown-it-github-alerts | 1.0.1 | MIT |
| markdown-it-mark | 4.0.0 | MIT |
| markdown-it-task-lists | 2.1.1 | ISC |
| Mermaid | 12.2.0 | MIT，随仓库放在 `web/vendor/`，许可证全文见 `web/vendor/mermaid.LICENSE` |
