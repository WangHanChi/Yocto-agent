# yocto-recipe-gen

一個給 [OpenCode](https://opencode.ai) 用的 [Agent Skill](https://agentskills.io)，讓
Qwen（或其他你設定好的 model）能根據你給的原始碼——git 網址、tar.gz（URL 或本機路徑）、
或本機資料夾——自動產生一份 Yocto/OpenEmbedded BitBake recipe，並且用真實的 `bitbake`
build 結果當 ground truth，跑一個「build → 讀錯誤 → 修 recipe」的自動修復迴圈，直到 build
成功或超過重試上限為止。

這個 skill 本身只是一組給 LLM 讀的指示文件（`SKILL.md`）加上幾支輔助 script，**執行時
仍然需要你自己已經有一個初始化好的 Yocto/poky build 環境**（`source oe-init-build-env`
過），skill 不會幫你建立整套 poky。

## 這個 skill 做什麼

1. **判斷輸入型態**：git URL / 壓縮檔（URL 或本機路徑）/ 本機資料夾，分別用對應方式取得
   原始碼。本機資料夾會問清楚你要「開發模式（`externalsrc`，快但不可重現）」還是
   「vendor tarball（打包進 layer，可重現）」。
2. **偵測 build system**（autotools / cmake / meson / cargo / python3 / kernel module /
   qmake / 純 Makefile），對照到正確的 bitbake class。
3. **用 `recipetool create` 產生 baseline**，再由 agent 精修 LICENSE /
   `LIC_FILES_CHKSUM` / `SRCREV` pin / `DEPENDS` / `do_install` 這幾個
   `recipetool` 常常猜不準的地方。
4. **Build-fix loop**：反覆執行 `bitbake <recipe>`，把巨大的 build log 濃縮成分類過的
   錯誤摘要，對照內建的症狀 → 成因 → 修法對照表動手改 recipe，直到成功或達重試上限
   （預設 8 輪），並保留每輪的完整 log 與改動紀錄。
5. 也可以直接指向一個**已經存在但 build 失敗的 recipe**，跳過產生步驟，直接進入
   build-fix loop。

## 專案結構

```
SKILL.md                  agent 實際遵循的完整流程說明（核心檔案）
scripts/
  fetch_source.sh          判斷輸入型態並把原始碼暫存下來
  detect_build_system.py   掃描原始碼樹猜測 build system
  license_scan.py          找授權檔、算 md5、粗略猜 SPDX 值（輔助用，非權威）
  parse_bitbake_log.py     把 bitbake log 濃縮成分類過的錯誤摘要
  build_loop.sh             跑「一輪」build（parse-only 檢查 + 實際 build），存 log
references/                Yocto recipe 語法、bbclass 對照、錯誤修法對照表等背景知識
templates/                 各 build system 的乾淨 .bb 骨架
examples/opencode.json.example   範例 provider/agent 設定（Qwen + 建議的 bash 權限）
```

## 安裝

OpenCode 會沿著目前目錄往上找 `.opencode/skills/<name>/SKILL.md`、
`.claude/skills/<name>/SKILL.md`、`.agents/skills/<name>/SKILL.md`，或是全域的
`~/.config/opencode/skills/<name>/SKILL.md`。**資料夾名稱必須等於 `SKILL.md`
frontmatter 裡的 `name`（`yocto-recipe-gen`）**，跟這個 GitHub repo 自己的名字無關，
所以 clone 的時候要指定目的資料夾名稱：

```sh
# 全域安裝（所有專案都能用）
git clone <this-repo-url> ~/.config/opencode/skills/yocto-recipe-gen

# 或只裝在某個 BSP 專案裡
git clone <this-repo-url> /path/to/your/bsp-project/.opencode/skills/yocto-recipe-gen
```

## 設定 Qwen model

參考 `examples/opencode.json.example`，把它合併進你的 `opencode.json`（或
`~/.config/opencode/opencode.json`），依你實際使用的 Qwen provider（DashScope /
Alibaba Cloud、本機 Ollama、或其他 OpenAI-compatible endpoint）調整 `baseURL` /
`apiKey` / model 名稱。範例裡把常用的 bitbake 系列指令設成 `allow`，`rm -rf /*`
設成 `deny`，其餘 bash 指令預設 `ask`，可依你的信任程度調整。

## 使用方式

在一個已經 `source`d 過 build 環境的 Yocto 專案目錄下，開 OpenCode，直接跟 agent說明
需求即可，例如：

```
幫我把 https://github.com/example/foo 這個 repo 做成一個 Yocto recipe，
放進 meta-mylayer，並且確保它能 build 成功。
```

或修一個現有的失敗 recipe：

```
meta-mylayer/recipes-support/foo/foo_1.0.bb 這個 recipe build 會失敗，幫我修好它。
```

Agent 會依照 `SKILL.md` 的流程走完整個「產生 → build → 讀錯誤 → 改 → 再 build」的
迴圈，並在結束時（不論成功或失敗）給你一份清楚的總結，包含它做了哪些關鍵判斷
（尤其是 LICENSE，**這一項務必人工複查**）。

## 限制與注意事項

- **需要真實的 bitbake 環境**：這個 skill 不會、也不應該幫你安裝/初始化整套 poky；
  它假設你已經在一個能跑 `bitbake` 的目錄裡。
- **LICENSE 判斷是輔助，不是權威**：`license_scan.py` 只是關鍵字比對，任何自動判斷出的
  授權欄位在正式使用前都需要人工複查，這在 `SKILL.md`／`references/license-guide.md`
  裡有明確要求 agent 每次都要在總結裡列出來提醒使用者。
- **cargo / npm / qmake5 等需要額外 layer 或工具**（`meta-nodejs`、`meta-qt5`、
  `cargo-bitbake`）：skill 會提醒缺什麼，但不會自動幫你加 layer 或裝工具。
- 建議把要修改的 meta-layer 放在 git 版控下，build-fix loop 每輪都會建議用
  `git diff`/`git checkout` 追蹤與回復改動。

## Roadmap

- 整合 `devtool` 工作流程（`devtool add`/`devtool build` 取代部分手動步驟）。
- `cargo-bitbake` 自動呼叫，取代目前需要手動產生 crate SRC_URI 清單的步驟。
- 批次模式：一次處理多個相依 recipe（例如一個上游 mono-repo 拆多個 package）。
- ptest 專屬的失敗診斷與修復流程。

## License

MIT，見 [LICENSE](LICENSE)。
