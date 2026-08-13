# Build System → bbclass 對照表

`scripts/detect_build_system.py` 判斷出的 `build_system` 值對應到下表，agent 依此決定
`inherit` 哪個 class，並注意各自常見的坑。

| build_system | inherit | 常見坑 |
|---|---|---|
| `autotools` | `autotools` | 上游若不支援 out-of-tree build（`./configure` 只能在原始碼目錄跑），改用 `inherit autotools-brokensep`。跨編譯常見卡在 `config.sub`/`config.guess` 太舊 → `inherit autotools` 通常會自動更新，若沒有要手動 `EXTRA_AUTORECONF`。 |
| `cmake` | `cmake` | 預設 generator 是 Ninja；上游若寫死 `find_package` 找系統路徑，跨編譯會抓到 host 的庫，要確認上游 CMake 有正確用 `CMAKE_FIND_ROOT_PATH`（OE 的 toolchain file 有設，但上游的 CMakeLists.txt 邏輯不對時還是會踩雷）。`EXTRA_OECMAKE` 加額外 `-D` 參數。 |
| `meson` | `meson` | 跟 cmake 類似的跨編譯 find 陷阱；`EXTRA_OEMESON` 加參數；meson option 用 `-Dfoo=enabled/disabled` 而非 autotools 的 `--enable-foo`。 |
| `cargo` | `cargo` | **需要額外工具**：用 `cargo-bitbake`（獨立安裝的工具，不在 poky 內建）從專案的 `Cargo.lock` 產生完整的 crate SRC_URI 清單，手動列 crates 幾乎不可行。沒有網路時（`BB_NO_NETWORK`）要確保所有 crate 都已經在 SRC_URI 裡列出並被快取，不能依賴 build 時連網抓 crates.io。 |
| `python3` | `python_setuptools_build_meta` / `python_hatchling` / `python_flit_core`（依 `pyproject.toml` 裡 `[build-system].build-backend` 而定）或舊式 `setuptools3`（只有 `setup.py`、沒有 `pyproject.toml` 時） | 先看 `pyproject.toml` 的 `build-backend` 字串再選 class，猜錯會在 do_compile 直接失敗說找不到 backend。Runtime python 相依要另外查 `RDEPENDS:${PN}`，setuptools 不會自動幫你加。 |
| `npm` | 需要 `meta-nodejs` layer 提供的 `node-npm`/`npm` bbclass（不在 oe-core） | 先確認目標環境有沒有引入 `meta-nodejs`；沒有的話要先跟使用者確認要不要加這個 layer，而不是假裝 oe-core 內建支援。 |
| `kernel-module` | `module`（來自 `meta`/oe-core 的 `module.bbclass`） | 一定要有 `inherit module`，且要能找到目標 kernel 的 `KERNEL_SRC`/staging（通常透過同一個 build 裡已經 build 過的 `virtual/kernel`）；`KERNEL_MODULE_AUTOLOAD`/`KERNEL_MODULE_PROBECONF` 視需求設定開機自動載入。 |
| `qmake5` | `qmake5` | 需要目標環境已經有 `meta-qt5`（Qt 已不在 oe-core），先確認 layer 是否存在。 |
| `generic-makefile` | 不 inherit 任何 class，手動寫 `do_compile`/`do_install` | 最容易漏東西的一種：CFLAGS/LDFLAGS 交叉編譯旗標要自己透過 `TARGET_CC_ARCH`/`${CC}` 傳進 make，不能假設上游 Makefile 有正確處理 cross-compile prefix。`do_install` 一定要手動 `install -d`/`install -m` 把產物放進 `${D}`，class 不會幫你做。 |
| `unknown` | — | `detect_build_system.py` 沒把握時，先看 `recipetool create` 自己猜出什麼 class，通常比純規則式偵測準；仍不確定就打開原始碼樹自己看有沒有隱藏的 build 腳本（`build.sh`、`bootstrap.sh`…）。 |

## 通則

- 能用標準 class 就不要手刻 `do_compile`/`do_install` —— 標準 class 已經處理好交叉編譯旗標、
  parallel make、staging 等細節，手刻容易漏掉這些。
- 只有 `generic-makefile` 或真的很特殊的上游 build 流程，才需要整段覆寫。
