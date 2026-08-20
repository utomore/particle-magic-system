---
id: F007
type: feature
title: packaging-content
description: 三平台共享函式庫的產物內容、版本檔與清單守門
status: open
created: 2026-08-20
updated: 2026-08-20
depends-on: []
related-adr: [ADR-021, ADR-025]
related-feature: []
---

# F007: 封裝內容（產物的形狀）

## 功能概述

宿主拿到的不是原始碼，是一包檔案。本功能定義**那一包裡有什麼**：三個平台各自的共享函式庫、可直接連結的匯入庫、標頭、版本檔，以及一份機器可讀的產物清單；再把清單與 `docs/release.md` 用守門測試釘在一起，讓「少一個檔」在 `cabal test` 就紅。

對應 [design.md](../design.md)「功能規劃 → 階段一 #7 packaging-content」，實作 **C4 封裝契約**，負責模組 **M7 封裝與整合文件**。不在執行期管線上——本功能不改變任何一個位元的模擬輸出，只改變產物的形狀。

**驗收標準**（照契約卡，逐條）：

1. Linux 產物以工具驗證不相依發行版的 libgmp／libffi，並在 WSL 實測。**手段是實作自主權**——本文件的查證推翻了「standalone」這個手段（見下），改以自帶執行期資料夾達成同一個目標，並把驗收語句改寫為可機械檢查的形式（見「待確認假設 A1」）。
2. Windows 產物附 MSVC 可直接連結的匯入庫，並以 MSVC 編譯的宿主跑通。**本輪已有機械證據**（見「相依性查證」§2），不是紙上規格。
3. macOS 產物（x86_64 與 arm64、`@rpath`）**只寫規格與建置設定**，驗證待 `authoring-engineering` 的 platform-matrix-macos 落地；清單與文件必須標明「未驗證」。
4. 版本檔內容與套件版本、ABI 世代一致。
5. 產物清單由守門測試比對。
6. 整合指南新增 MSVC 連結與 macOS `@rpath` 章節。

**明確不做**（照契約卡）：不擁有 CI 的建置與上傳流程（屬 authoring-engineering 的 release-artifacts）；不做安裝器；不簽章或公證；不在沒有 macOS 的情況下宣稱 macOS 已驗證。另外本輪不動 `include/particle_magic.h` 的任何宣告、不動 `particle-magic-ffi.def` 的符號清單、不改任何匯出符號的行為，`PM_ABI_VERSION` 不動。

## 相依性

`depends-on: []`——**可與階段一的其他 feature 完全平行開發**。

理由由下方「使用到的既有串接介面」表反推：每一列的來源文檔欄都是 `-`，也就是本功能用到的東西全部是**今天就存在於工作樹裡的檔案**（標頭的常數與宣告、cabal 的 `version:` 與 foreign-library stanza、`.def` 的匯出清單、`cbits/pm_init.c` 的兩個 C 匯出、既有的三份守門測試），沒有任何一列指向尚未落地的文檔介面。

與同階段幾個相鄰項的關係，全部是「不相依」而非「先後」：

- **#6 oop-load-smoke**：它的驗收自帶一句「hspec 只守護它在出貨清單中」。本功能定義的清單**不預留** `test/oop/` 的位置——那是 #6 落地時往清單裡加一列的事，兩邊沒有呼叫關係，也沒有共用資料結構。
- **#8 host-doc-corrections**：兩者都改 `docs/integration.md`，但改的是**不同章節**（本功能加 §4 的 MSVC 連結與 macOS `@rpath` 兩節；#8 改 §8 誠實清單與範例的容量／時步敘述）。文字衝突的風險屬編排順序，不是設計相依。
- **authoring-engineering/release-artifacts**：對方的契約卡明寫「不定義產物內容（屬 host-runtime）」，且它的依賴欄指向本功能。方向是單向的——本功能產出清單，對方讀同一份清單去上傳。

## 對應的 Level 2 契約

實作 [design.md](../design.md) 的 **C4 封裝契約**，逐條對照：

| C4 的列 | 本功能怎麼實作 | 是否超出範圍 |
|---|---|---|
| Windows x86_64：standalone DLL ＋ MinGW 匯入庫 ＋ **MSVC 匯入庫** ＋ 標頭 | standalone DLL 與 `.dll.a` 是既有建置的產物，本功能只是把它們列進清單；MSVC `.lib` 由 `lib.exe /def:` 從既有 `.def` 產生 | 否 |
| Linux x86_64：**standalone** `.so`（不再動態相依 libgmp／libffi）＋ 標頭 | **手段改變、目標不變**：standalone 經實測在本專案的工具鏈上不可行，改以「`.so` ＋ 其共享物件閉包 ＋ `$ORIGIN`」達成「不相依 GHC 安裝、不相依發行版 libgmp／libffi」。這一條要編排者裁決（待確認假設 A1） | **形式偏離，目標不偏離** |
| macOS x86_64／arm64：`.dylib`（兩架構）＋ 標頭；`install_name` 以 `@rpath` 為基準 | 只寫 cabal 的連結選項與打包腳本的分支，清單標 `verified: false` | 否 |
| 每份產物附版本檔（套件版本、ABI 世代、建置平台、commit） | `pm-version.json`，四個欄位一個不多 | 否 |
| 產物清單由守門測試與 CI 上傳步驟比對——少一個檔就紅 | `packaging/artifacts.json` ＋ `test/PackagingSpec.hs`；CI 上傳步驟不屬本功能 | 否 |

同時消費（不改變）**I5「M5／M6／M7 → 標頭」**：本功能只認標頭與 `.def`，不認 `Magic.FFI` 的任何 Haskell 型別。

**未超出的證明**：本功能不新增任何 C 符號、不新增任何 Haskell 匯出、不新增任何 JSON 鍵。新增的三樣東西（產物清單、版本檔、打包腳本）全部落在 C4 的「產物的內容」之內。

## 實作方式

### 1. 為什麼 Linux 不能走 standalone（這一段決定了整個 Linux 分支）

`options: standalone` 在 Cabal 3.16.1.0 的平台檢查裡**不會**被 Linux 拒絕（`goGhcLinux` 只擋 `mod-def-file` 與版本欄位衝突），但 `withDynFLib` 讓 standalone ⇒ 不走 dynamic way ⇒ GHC 拿**靜態封存檔**去連 `.so`。而 ghcup 的 GHC 9.14.1 Linux bindist 的靜態封存檔不是 PIC（實測見下節），`ld` 於是拒絕：

```
relocation R_X86_64_32S against symbol `...' can not be used when
making a shared object; recompile with -fPIC
```

把 `-fPIC` 加到本專案的三個 stanza 之後，錯誤只是**往後移一格**——改成 cabal store 裡的 `parallel-3.3.0.0` 封存檔炸，而它後面還排著 `base`、`ghc-internal`、`rts` 這些**隨 bindist 預編好、我們改不動**的封存檔。結論是工具鏈層級的：**stock ghcup GHC 下，Linux 的 foreign-library 只能連動態 way**。

Windows 之所以可以 standalone，是因為 PE 沒有 PIC 這道門檻，跟本專案的寫法無關。

### 2. Linux 的實際做法：自帶執行期資料夾

今天的 Linux 產物比契約卡假設的更糟——不是「多相依兩個系統庫」，是**根本離不開開發機**：254 KB 的 `.so`、70 條 `NEEDED`、`RUNPATH` 寫死 `~/.local/state/cabal/store` 與 `~/.ghcup` 的絕對路徑。`libgmp.so.10` 與 `libffi.so.8` 只是這串相依的末端（分別由 `libHSbase`／`libHSghc-internal` 與 `libHSrts-1.0.3_thr` 帶進來；我們自己的 `.so` 對 `__gmp*`／`ffi_*` 的未定義符號數是 **0**）。

打包腳本因此做三件事：

1. **蒐集閉包**：對建出的 `.so` 走 `ldd`，把每一個解析到 `~/.ghcup`、cabal store、以及 GHC 自帶的 `libffi.so.8`／系統 `libgmp.so.10` 的檔案複製進產物資料夾；只留 `libc`／`libm`／`libpthread`／`libdl`／`librt` 這幾個 glibc 本體不帶（帶了反而危險）。
2. **把載入路徑改成相對**：連結時下 `-optl-Wl,-rpath,$ORIGIN`；若 `$ORIGIN` 在 cabal→GHC→gcc→ld 的傳遞中被吃掉（未實測，見 A2），退回打包後製（`patchelf --set-rpath '$ORIGIN'`）。兩條路都是實作自主權，產物的形狀不變。
3. **驗證**：`pack.sh --verify` 在 `env -i` 的乾淨環境下、只把產物資料夾放進搜尋路徑，斷言 `ldd` 的 `not found` 數為 0，且**沒有任何一條解析路徑落在產物資料夾之外**。這一條就是「以工具驗證不相依 libgmp／libffi」的可機械檢查版本——它比原文更強：不只 gmp／ffi，是整個閉包。

已實測這條路走得通（見「相依性查證」§3 的 dlopen 結果）。

### 3. Windows：MSVC 匯入庫

既有建置已經給出 `particle-magic-ffi.dll`（standalone、約 45.7 MiB）與 `particle-magic-ffi.dll.a`（MinGW 匯入庫）。MSVC 宿主需要的是 COFF 匯入庫，兩種產法**都已實測可用**：

- 首選 `lib.exe /nologo /def:particle-magic-ffi.def /machine:x64 /out:particle-magic-ffi.lib`——直接吃 repo 裡那份 `.def`，一個字都不用改。
- 沒有 MSVC 時退回 ghcup 隨附的 `llvm-dlltool -m i386:x86-64 -d particle-magic-ffi.def -D particle-magic-ffi.dll -l particle-magic-ffi.lib`。

腳本先用 `vswhere` 找 MSVC，找不到就走 dlltool，並把用了哪一條寫進版本檔以外的建置紀錄（stdout 即可，不進產物）。

### 4. macOS：只寫設定

cabal 的 foreign-library 在 macOS 只允許 `native-shared`，且 Cabal **不會**替 foreign-library 設 `install_name`。因此 `@rpath` 必須自己下：

```
if os(darwin)
    ghc-options: "-optl-Wl,-install_name,@rpath/libparticle-magic-ffi.dylib"
```

雙架構的產法（分別建再 `lipo -create`，或 `-optc-arch`／`-optl-arch`）留給實作，因為在沒有機器的情況下寫死任何一種都是猜。清單裡 macOS 平台項標 `verified: false`，`docs/release.md` 與 `docs/integration.md` 同步標明。

### 5. 產物清單與版本檔

清單 `packaging/artifacts.json` 是**唯一權威**：平台 → 檔案清單（每檔一個 `name` 與 `role`）＋ 版本檔的欄位 schema。`docs/release.md` 新增一節用表格複述同一份清單，`test/PackagingSpec.hs` 斷言兩者**雙向相等**——沿用 `ReleaseDocSpec` 對平台清單的既有作法（掃文件裡的字串集合，與另一端比對集合相等），不需要在測試裡剖析 JSON 以外的東西。

版本檔 `pm-version.json` 放在每份產物資料夾根目錄，四個欄位：`package-version`（讀 cabal `version:`）、`abi-version`（讀標頭 `PM_ABI_VERSION`）、`platform`（平台三元組，等於清單的平台 id）、`commit`（`git rev-parse HEAD`，取不到寫 `unknown`）。生成由兩支腳本各自負責（POSIX 一支、PowerShell 一支），守門測試斷言**兩支腳本寫出的欄位集合與清單的 schema 三方相等**，並獨立地從 cabal 與標頭把那兩個常數再讀一次，確認來源路徑沒有漂走。

錯誤處理：打包腳本在找不到建置產物、閉包不完整、或 `--verify` 失敗時以非零退出碼收場，訊息指出是哪一個檔——它會被 CI 直接消費（release-artifacts），所以退出碼比訊息重要。

### 6. 新增檔案要記得掛上

`test/PackagingSpec.hs` 要進 `particle-magic.cabal` 的 test-suite `other-modules`（`test/Spec.hs` 是 hspec-discover，但 cabal 仍要列）。`packaging/` 底下的檔案是否要進 `extra-source-files` 由實作決定——`ExampleHostSpec` 的出貨清單斷言只掃 `examples/haskell/`，不會被影響。

## 使用到的既有串接介面

| 介面（含完整簽名） | 來源檔案 | 來源文檔 | 用途 |
|---|---|---|---|
| `#define PM_ABI_VERSION 1` | `include/particle_magic.h`:98 | - | 版本檔 `abi-version` 的唯一來源；守門測試獨立再讀一次 |
| `int pm_abi_version(void);` | `include/particle_magic.h`:170 | - | MSVC 宿主 smoke 啟動時比對世代（`pm_msvc.exe` 已實測回 1） |
| `int pm_max_particles(void);` | `include/particle_magic.h`:176 | - | Linux 閉包驗證的 dlopen 探針呼叫它證明 RTS 真的活著（實測回 16384） |
| `void pm_init(void);` / `void pm_shutdown(void);` | `include/particle_magic.h`:164,167 | - | 同上；也是 `.def` 裡兩個非 Haskell 匯出的來源 |
| `PM_EXPORT void pm_init(void)` / `PM_EXPORT void pm_shutdown(void)` | `cbits/pm_init.c`:40,53 | - | 說明為何 `.def` 必須列這兩個名字——它們是 C 而非 `foreign export`，Windows 端要靠 `.def` 才進匯入庫 |
| `EXPORTS`（31 個符號，`pm_init` … `pm_scene_spell_bounds`） | `particle-magic-ffi.def`:7-38（`EXPORTS` 在 7，符號在 8-38） | - | `lib.exe /def:` 與 `llvm-dlltool -d` 的**直接輸入**；本功能不改它一個字 |
| `version:            0.1.0.0` | `particle-magic.cabal`:10 | - | 版本檔 `package-version` 的唯一來源 |
| `foreign-library particle-magic-ffi` stanza（`type: native-shared`；`if os(windows)` 下 `options: standalone` 與 `mod-def-file: particle-magic-ffi.def`；`ghc-options: -Wall -O2 -threaded`） | `particle-magic.cabal`:230-247 | - | 本功能新增的連結選項掛在這裡（Linux 的 `$ORIGIN`、macOS 的 `install_name`），Windows 既有兩行不動 |
| `runnerLabels :: String -> [String]`（模組內部；三向比對平台清單的既有作法） | `test/ReleaseDocSpec.hs`:55-61 | - | 新守門測試沿用同一個模式（掃字串集合、雙向比對），不 import 它——spec 之間各自帶自己的小工具是本 repo 的既有紀律 |
| `allDepEntries :: String -> [String]`（續行判定＝「以逗號開頭」） | `test/ReleaseMetaSpec.hs`:61-73 | - | 提醒：在 stanza 裡加 `ghc-options` 行不會擾動它，但**不得**把相依項改成非逗號開頭的寫法 |
| `extraSourceFiles :: IO [FilePath]` / `exampleFiles :: IO [FilePath]`（出貨清單斷言，只掃 `examples/haskell`） | `test/ExampleHostSpec.hs`:364-365,395-398 | - | 確認新增 `packaging/` 不會撞到既有的出貨清單守門 |
| `{-# OPTIONS_GHC -F -pgmF hspec-discover #-}` | `test/Spec.hs`:1 | - | 新 spec 會被自動發現，但仍要進 cabal `other-modules` |

## 新增的介面

全部落在 C4「產物的內容」之內；**沒有任何一項是 C 符號、Haskell 匯出或 JSON 輸入格式的變動**。

### N1 產物清單 `packaging/artifacts.json`

機器可讀的唯一權威。形狀（欄位名為契約，值為示意）：

```json
{
  "version-file": {
    "name": "pm-version.json",
    "fields": ["package-version", "abi-version", "platform", "commit"]
  },
  "platforms": [
    {
      "id": "windows-x86_64",
      "verified": true,
      "files": [
        { "name": "particle-magic-ffi.dll",   "role": "runtime" },
        { "name": "particle-magic-ffi.dll.a", "role": "import-lib-mingw" },
        { "name": "particle-magic-ffi.lib",   "role": "import-lib-msvc" },
        { "name": "particle_magic.h",         "role": "header" },
        { "name": "pm-version.json",          "role": "version" }
      ]
    },
    { "id": "linux-x86_64",  "verified": true,  "files": [ … "runtime", "runtime-closure", "header", "version" ] },
    { "id": "macos-x86_64",  "verified": false, "files": [ … "runtime", "header", "version" ] },
    { "id": "macos-arm64",   "verified": false, "files": [ … ] }
  ]
}
```

- `role` 是**封閉詞彙**：`runtime`、`runtime-closure`、`import-lib-mingw`、`import-lib-msvc`、`header`、`version`。守門測試斷言沒有清單外的角色。
- `verified` 是誠實欄位：`false` 代表「規格與建置設定寫好了，沒有機器驗過」。macOS 兩列在本輪一律 `false`。
- `runtime-closure` 是 Linux 專用的一列，指的是與 `.so` 同層的共享物件集合（檔數與內容隨相依解析而變，因此清單記的是**這個角色存在**，實際檔案由 `pack.sh --verify` 保證自足）。

### N2 版本檔 `pm-version.json`

每份產物資料夾根目錄一份，四個欄位：

| 欄位 | 型別 | 來源 |
|---|---|---|
| `package-version` | string | `particle-magic.cabal` 的 `version:` |
| `abi-version` | number | `include/particle_magic.h` 的 `PM_ABI_VERSION` |
| `platform` | string | 清單的平台 `id`（`windows-x86_64` 等） |
| `commit` | string | `git rev-parse HEAD`；取不到寫 `unknown` |

### N3 打包腳本

| 腳本 | 平台 | 職責 |
|---|---|---|
| `packaging/pack.ps1` | Windows | 蒐集 DLL 與 MinGW 匯入庫、產 MSVC 匯入庫（`lib.exe /def:`，退回 `llvm-dlltool`）、複製標頭、寫版本檔 |
| `packaging/pack.sh` | Linux／macOS | 蒐集 `.so`／`.dylib` 與（Linux）共享物件閉包、複製標頭、寫版本檔；`--verify` 做乾淨環境的自足性檢查 |
| `packaging/smoke-msvc.ps1` | Windows | 以 `cl.exe` 編 `examples/c/main.c` 連 MSVC 匯入庫並跑一次完整生命週期，退出碼即結論 |

三支腳本的退出碼語意一致：0 ＝ 產物齊全且（`--verify` 時）自足，非 0 ＝ 指出缺哪一個檔或哪一條相依沒解析到。

### N4 連結選項（掛在既有 foreign-library stanza）

| 平台 | 新增 | 既有（不動） |
|---|---|---|
| Windows | 無 | `options: standalone`、`mod-def-file: particle-magic-ffi.def` |
| Linux | `-optl-Wl,-rpath,$ORIGIN`（或等效的打包後製） | — |
| macOS | `-optl-Wl,-install_name,@rpath/libparticle-magic-ffi.dylib` | — |

## TodoList

- [ ] T1: 建立 `packaging/artifacts.json`：四個平台項、封閉的 `role` 詞彙、`verified` 欄、版本檔 schema　`dep: -`
- [ ] T2: `docs/release.md` 新增「發布產物」一節，以表格複述同一份清單（含 macOS 未驗證的標註）　`dep: T1`
- [ ] T3: 版本檔生成：`pack.sh` 與 `pack.ps1` 各自從 cabal `version:` 與標頭 `PM_ABI_VERSION` 讀值，寫出四欄位的 `pm-version.json`　`dep: T1`
- [ ] T4: `packaging/pack.ps1`：DLL ＋ MinGW `.dll.a` ＋ `lib.exe /def:` 產 MSVC `.lib`（退回 `llvm-dlltool`）＋ 標頭 ＋ 版本檔　`dep: T1, T3`
- [ ] T5: `packaging/smoke-msvc.ps1`：以 `cl.exe` 編 `examples/c/main.c` 連 MSVC 匯入庫，跑完 120 幀生命週期　`dep: T4`
- [ ] T6: `packaging/pack.sh` 的 Linux 分支與 `-optl-Wl,-rpath,$ORIGIN`（必要時後製）：蒐集閉包、`--verify` 在乾淨環境驗自足　`dep: T1, T3`
- [ ] T7: macOS 建置設定：`if os(darwin)` 的 `install_name` 選項、`pack.sh` 的 dylib 與雙架構分支、清單與文件標 `verified: false`　`dep: T1, T6`
- [ ] T8: `docs/integration.md` 新增「MSVC 連結」與「macOS `@rpath`」兩節；`test/PackagingSpec.hs` 進 cabal `other-modules`　`dep: T4, T7`

## 1-to-1 測試對照表

| Todo | 測試 | 說明 |
|------|------|------|
| T1 | `PackagingSpec`「產物清單可解析且四個平台齊全」 | `packaging/artifacts.json` 解析成功；平台 id 集合恰為 `{windows-x86_64, linux-x86_64, macos-x86_64, macos-arm64}`；每個 `role` 都在封閉詞彙內；Windows 項同時含 `import-lib-mingw` 與 `import-lib-msvc`；空清單以非空斷言擋掉（沿用 `ReleaseDocSpec` 的 vacuity guard 紀律） |
| T2 | `PackagingSpec`「清單 ↔ `docs/release.md` 雙向相等」 | 清單裡的每個檔名都出現在 release.md 的產物章節，且該章節提到的每個檔名都在清單裡；macOS 兩列在文件中帶「未驗證」字樣 |
| T3 | `PackagingSpec`「版本檔欄位三方相等，且兩個常數來源仍在」 | 清單 schema 的欄位集合 ＝ `pack.sh` 寫出的欄位集合 ＝ `pack.ps1` 寫出的欄位集合；測試獨立從 cabal 解出 `version:`、從標頭解出 `PM_ABI_VERSION`，兩者皆非空且格式正確 |
| T4 | `PackagingSpec`「Windows 匯入庫以 `.def` 為輸入」 | `pack.ps1` 的內容提到 `particle-magic-ffi.def` 與兩條產法（`lib.exe` 與 `llvm-dlltool`）；`.def` 的 `EXPORTS` 符號數與 `include/particle_magic.h` 宣告的匯出集合仍一致（不重寫 `FFIContractSpec`，只斷言 `.def` 未被本輪改動的符號數 31） |
| T5 | 手動／腳本 smoke：`smoke-msvc.ps1` 退出碼 0 | `cl.exe` 連 MSVC 匯入庫編出的宿主跑完 120 幀、印出 `finished: 0`、`dumpbin /dependents` 只有 `particle-magic-ffi.dll` 與 `KERNEL32.dll`；hspec 只守護這支腳本列在清單／文件中（與 #6 oop-load-smoke 同一條紀律） |
| T6 | WSL 實測：`pack.sh --verify` 退出碼 0 | 乾淨環境（`env -i`，只有產物資料夾在搜尋路徑上）下 `ldd` 的 `not found` 數為 0，且沒有任何解析路徑落在資料夾之外（涵蓋 libgmp／libffi 與全部 `libHS*`）；dlopen 後 `pm_init` ＋ `pm_abi_version()` ＋ `pm_max_particles()` 成功 |
| T7 | `PackagingSpec`「macOS 只寫設定且誠實標註」 | cabal 有 `install_name` 與 `@rpath` 的選項行；清單的兩個 macOS 平台項 `verified: false`；`pack.sh` 內容提到 `.dylib` 與雙架構 |
| T8 | `PackagingSpec`「整合指南有 MSVC 與 `@rpath` 兩節」 | `docs/integration.md` 含 MSVC 連結章節（提到 `lib.exe`／`.lib`）與 macOS `@rpath` 章節；新 spec 已列入 cabal `other-modules`（以掃 cabal 檔斷言，沿用 `ExampleHostSpec` 的作法） |

## 待確認假設

- **A1: C4 的 Linux 列「standalone `.so`」在本專案的工具鏈上做不到。** → 採取：改以「`.so` ＋ 共享物件閉包 ＋ `$ORIGIN`」達成同一個目標（宿主不需要安裝 GHC 執行期、不相依發行版的 libgmp／libffi），並把驗收語句改寫為「乾淨環境下閉包自足、零外部解析」——這比原文更強。→ 影響：若編排者要求字面上的 standalone，本 feature 的 Linux 項**變成阻塞**，出路只有「換一個靜態庫為 PIC 的 GHC」，那是工具鏈決策，要新 ADR，且會牽動 ADR-021 與 CI 的安裝步驟。建議編排者裁決是否修訂 C4 的 Linux 列措辭。
- **A2: `$ORIGIN` 能否原樣穿過 cabal → GHC → gcc → ld 未實測。** → 採取：設計允許實作退回打包後製（`patchelf --set-rpath '$ORIGIN'`）。→ 影響：只影響實作手段，產物形狀不變。注意本機 WSL Debian **沒有 patchelf**（實測 `command -v patchelf` 為空），走後製路線要先裝，或在 CI 的 Linux job 裝。
- **A3: macOS 全部未驗證。** → 採取：只寫連結選項與腳本分支，清單與文件標 `verified: false`。→ 影響：platform-matrix-macos 落地時，`install_name` 的寫法、雙架構的產法、以及「macOS 是否也踩 Linux 的 PIC 問題」（macOS 目的碼預設 PIC，**推測** standalone 在 macOS 可行，但沒有機器可證）都可能要改。
- **A4: 版本檔的 `commit` 在非 git 環境（例如從 sdist 解出來建置）取不到。** → 採取：寫 `unknown`，守門測試只驗欄位存在、不驗值。→ 影響：若日後要求 commit 必須是真值，得改成建置時注入，屬 CI 的事。
- **A5: CI 的 windows-latest 上 `lib.exe` 是否在 PATH 未查證。** → 採取：`pack.ps1` 先用 `vswhere` 找 MSVC，找不到退回 `llvm-dlltool`；本機兩條路都已實測可連結。→ 影響：只影響 CI 步驟（不屬本 feature）。
- **A6: 產物清單的位置與格式由本文件自行決定（`packaging/artifacts.json`）。** → 採取：JSON，唯一權威在檔案本身，文件複述、測試比對——與 authoring-engineering 的「文字合約」模式同型。→ 影響：release-artifacts 若偏好別的位置，改一個路徑常數即可，格式不必動。

## 實作備註

（撰寫時留空）
