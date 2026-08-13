# yocto-recipe-gen

[English](README.md) | **繁體中文**

一個給 [OpenCode](https://opencode.ai) 用的 [Agent Skill](https://agentskills.io)，讓
Qwen（或其他你設定好的 model）能根據你給的原始碼——git 網址、tar.gz（URL 或本機路徑）、
或本機資料夾——自動產生一份 Yocto/OpenEmbedded BitBake recipe，並且用真實的 `bitbake`
build 結果當 ground truth，跑一個「build → 讀錯誤 → 修 recipe」的自動修復迴圈，直到 build
成功或超過重試上限為止。

這個 skill 本身只是一組給 LLM 讀的指示文件（`SKILL.md`）加上幾支輔助 script，**執行時
仍然需要你自己已經有一個初始化好的 Yocto/poky build 環境**（`source` 得起來的環境），
skill 不會幫你建立整套 poky。

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
  build_loop.sh            跑一輪 build（parse-only 檢查 + 實際 build），存 log
  run_in_env.sh            先 source 專案的 Yocto+SDK 環境，再執行 bitbake 家族指令
  env_setup.sh             上面兩支 script 共用的環境解析邏輯（被 source，不直接執行）
references/                Yocto recipe 語法、bbclass 對照、錯誤修法對照表等背景知識
templates/                 各 build system 的乾淨 .bb 骨架
examples/
  opencode.json.example              範例 provider/agent 設定（Qwen + 建議的 bash 權限）
  yocto-recipe-gen.conf.example      範例環境設定檔
```

## 安裝

這個 skill 採用開放的 [`SKILL.md`](https://agentskills.io) 標準，所以在 OpenCode 和
Claude Code 的安裝方式一樣：就是把一個「以 skill 名稱命名的資料夾」放進該工具會掃描的
`skills/` 目錄裡。**資料夾名稱必須等於 `SKILL.md` frontmatter 裡的 `name`
（`yocto-recipe-gen`）**，跟這個 GitHub repo 自己的名字無關，所以 clone 的時候要指定
目的資料夾名稱。

### OpenCode

OpenCode 會沿著目前目錄往上找 `.opencode/skills/<name>/SKILL.md`、
`.claude/skills/<name>/SKILL.md`、`.agents/skills/<name>/SKILL.md`，或是全域的
`~/.config/opencode/skills/<name>/SKILL.md`。

```sh
# 全域安裝（所有專案都能用）
git clone git@github.com:WangHanChi/Yocto-agent.git ~/.config/opencode/skills/yocto-recipe-gen

# 或只裝在某個 BSP 專案裡
git clone git@github.com:WangHanChi/Yocto-agent.git /path/to/your/bsp-project/.opencode/skills/yocto-recipe-gen
```

### Claude Code

Claude Code 會從 `~/.claude/skills/<name>/SKILL.md`（個人層級，所有專案共用）或專案內的
`.claude/skills/<name>/SKILL.md` 載入 skill。

```sh
# 個人安裝（所有專案都能用）
git clone git@github.com:WangHanChi/Yocto-agent.git ~/.claude/skills/yocto-recipe-gen

# 或只裝在某個 BSP 專案裡
git clone git@github.com:WangHanChi/Yocto-agent.git /path/to/your/bsp-project/.claude/skills/yocto-recipe-gen
```

裝好後，在 Claude Code 裡執行 `/skills`（或直接叫它幫你做 Yocto recipe），skill 就會被
自動辨識。下面的 build 環境設定（`.yocto-recipe-gen.conf`）在兩個工具上完全一樣。

> **關於 model：** 下面的 Qwen provider 設定是 OpenCode 專屬的。Claude Code 會用它自己
> 設定的 model 來跑這個 skill；skill 的邏輯（產生 recipe + build-fix loop）跟 model 無關，
> 兩邊都能用。

## 設定 Qwen model（OpenCode）

參考 `examples/opencode.json.example`，把它合併進你的 `opencode.json`（或
`~/.config/opencode/opencode.json`），依你實際使用的 Qwen provider（DashScope /
Alibaba Cloud、本機 Ollama、或其他 OpenAI-compatible endpoint）調整 `baseURL` /
`apiKey` / model 名稱。範例裡把常用的 bitbake 系列指令設成 `allow`，`rm -rf /*`
設成 `deny`，其餘 bash 指令預設 `ask`，可依你的信任程度調整。

## 設定你的 build 環境（重要）

因為 **agent 每下一個 Bash 指令都是一個全新的 shell**，你在前一個指令 `source` 過的環境
到下一個指令就沒了。所以這個 skill 會在每一個 bitbake 指令之前重新 source 你的環境。你透過
一個設定檔告訴它你的環境腳本在哪。

作為硬性守則，agent 在動工之前一定會先問你有沒有自己的 source 腳本：有的話你必須給它確切的
路徑或檔名；沒有的話它才會退回用標準的 `oe-init-build-env`。無論哪種情況，它都會先確認環境
真的 source 成功，才會開始做任何 recipe 的工作。

在你平常 `source` 環境的那個工作目錄下，建一個 `.yocto-recipe-gen.conf`（參考
`examples/yocto-recipe-gen.conf.example`）：

```sh
# 指向那支「會 source oe-init-build-env、也會 source SDK 環境（cross toolchain）」
# 的腳本的絕對路徑（如果你有 SDK 的話）。
ENV_SETUP="/home/you/yocto/setup-build-env.sh"
# 若該腳本需要參數，例如 build 目錄名：
# ENV_SETUP_ARGS="build"
```

- 所有一次性的 bitbake 家族指令都透過 `scripts/run_in_env.sh <指令>` 執行，它會先
  source `ENV_SETUP` 再跑。
- `scripts/build_loop.sh` 會自己 source，所以這支不用再包一層。
- 若你只用標準的 `oe-init-build-env`、沒有 SDK，就把 `ENV_SETUP` 指向一支一行的 wrapper
  （`source /path/to/poky/oe-init-build-env /path/to/builddir`），或直接指向 poky 的
  `oe-init-build-env`。

## 使用方式

在一個能 source 環境的 Yocto 專案目錄下，開 OpenCode（或 Claude Code），直接跟 agent
說明需求即可，例如：

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
