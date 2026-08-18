---
id: subarch-0006
type: subarch
title: authoring-engineering
description: 作者 CLI、JSON Schema、文件守門測試與 CI 發布政策
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0005, adr-0016]
---

# 作者工具與工程化 子系統架構

## 定位與範圍

[主架構 §2.1](architecture.md#21-子系統劃分) 六塊裡唯一**不在三環裡**的一塊。它的產物一行都不進出貨的庫，也不影響任何執行期行為——但沒有它，另外五塊沒辦法被別人使用、也沒辦法被安全地發布。

服務兩種人：**寫魔法陣的人**（要知道格式、要在存檔前就知道寫錯了、要看得到這張陣加起來是什麼）與**發布這個庫的人**（要知道哪些平台驗過、版本怎麼跳、哪些東西凍結了）。

**做**：

- 三支 CLI：`magic-validate`（驗證）、`magic-inspect`（報告）、`magic-schema`（機器可讀格式）
- 作者面文件：`docs/spell-schema.md` 手冊 ＋ `docs/spell.schema.json`
- 宿主面文件：`docs/integration.md` 接法指南、`docs/release.md` 發布政策
- **文件↔程式碼的守門測試**：讓文件過期會讓 CI 變紅
- CI 兩平台矩陣、PVP 版本政策、`v*` tag 發布流程

**明確不做**：

- **不進庫**。三支 CLI 都是獨立的 executable stanza，`magic-schema` 甚至**完全不依賴這個庫**——它的 schema 是一份手寫的宣告表，這正是 `magic-schema --check` 能當 golden 比對而不是「第二意見」的原因。
- **不做視覺化編輯器**。等有非工程作者為止（func-0014 §8-1）。demo 內的參數面板（[subarch-0005](subarch-0005-render-shell.md)）是這個方向的雛形，不是替代品。
- **不上 Hackage**（ADR-0016 明文否決）。

## 需求說明

1. **寫錯要在存檔前知道**，而不是在畫面上什麼都沒出現的時候猜。錯誤要附位置、要能一次看到全部而不是逐個修。
2. **格式要能被機器消費**：編輯器的 JSON 補全、CI 的 schema 步驟，都不該需要讀 Haskell。
3. **文件不能過期**。這個專案的文件量遠大於程式碼量，靠人維持同步不可行。
4. **「這個 commit 是好的」不能只依賴某一台機器**。

## 架構規劃

| 元件 | 檔案 | 職責 |
|---|---|---|
| 驗證 CLI | `tools/Validate.hs` ＋ `tools/Main.hs` → `magic-validate` | 載入並施放一份魔法陣檔，回報載入錯誤、編譯錯誤、預算與生命週期統計；支援 `--json` 機器可讀輸出與目錄批次 |
| 檢視 CLI | `tools/Inspect.hs` ＋ `tools/InspectMain.hs` → `magic-inspect` | 一份法術「加起來是什麼」的人類可讀報告。**每個數字都來自既有的 `Magic.Interface` 查詢**，工具不做自己的分析，只把答案排版 |
| Schema CLI | `tools/Schema.hs` ＋ `tools/SchemaMain.hs` → `magic-schema` | 產生／檢查 `docs/spell.schema.json`，並自帶一個 draft-07 子集的驗證器 |
| 作者手冊 | `docs/spell-schema.md`、`docs/spell.schema.json` | 人讀的一份、機器讀的一份，兩者互為 golden |
| 宿主指南 | `docs/integration.md` | 三條消費路徑的接法、固定 `dt` 假設、2D／像素風食譜、宿主責任清單 |
| 發布政策 | `docs/release.md`、`CHANGELOG.md`、`particle-magic.cabal` metadata | 平台分級、PVP 上界、`tested-with:`、`v<version>` tag 格式、`PM_ABI_VERSION` 與套件版本獨立遞增 |
| 進度盤點 | `docs/roadmap.md` | 欠款總表：每一條未落地項目都要在某份 spec 的 §9 裡有主 |
| CI | `.github/workflows/ci.yml` | `{windows-latest, ubuntu-latest}` 矩陣，build → test → validate；PR 到 main ＋ `v*` tag ＋ 手動觸發 |
| 守門測試 | `test/{SchemaDoc,JsonSchema,ReleaseDoc,ReleaseMeta,CIWorkflow,ExampleHost,BindingContract}Spec.hs` | 見下 |

### 這個子系統的核心技術：文字合約

本子系統最有價值的東西不是三支 CLI，而是一組把**文件當成被測物**的測試。模式一律相同：程式碼裡有事實，文件裡有敘述，測試斷言兩者相等。

| 測試 | 釘住的兩端 |
|---|---|
| `SchemaDocSpec` | 每個出貨的範例陣與每個符文 tag 都必須出現在 `docs/spell-schema.md` |
| `JsonSchemaSpec` | `docs/spell.schema.json` ↔ `Schema.generateSchema` ↔ `docs/spell-schema.md` 的三方一致 |
| `ReleaseDocSpec` | 平台支援清單在 `docs/release.md`、ADR-0016、CI 矩陣三處相同 |
| `ReleaseMetaSpec` | cabal 的 `version`／`tested-with` ↔ `CHANGELOG.md` ↔ `docs/release.md` |
| `CIWorkflowSpec` | CI 設定檔本身的觸發條件與矩陣 |
| `ExampleHostSpec` | `examples/haskell/` 的每個檔案都列在 `extra-source-files`；其 golden 以兩條獨立路徑重算 |
| `BindingContractSpec` | C# 參考綁定 ↔ `include/particle_magic.h` |

**代價與界線**：這招對「IO 端產生、純端比較相等」的東西有一個已知盲區——func-0014 §9.2 記到，Windows 的路徑分隔符讓「重掃 ≡ 啟動清單」的等式失效，程式照跑、只有 HUD 看得出來。結論寫成一條紀律：凡是這一類地方，都要有一條**打真檔案系統**的守護測試，外加一次人眼 smoke。

## 對外介面

CLI 的契約是旗標、退出碼與輸出格式：

```text
magic-validate <file|dir> [--json]
    exit 0  全部通過
    exit 1  有檔案載入或編譯失敗（--json 時輸出結構化報告）

magic-inspect <file>
    法術報告：預算、生命週期界標、發射器清單、空間包絡、blend/shape 分批

magic-schema [--check] [--out <path>]
    無旗標  把 JSON Schema 印到 stdout
    --check 與 docs/spell.schema.json 比對，不同則 exit 1（golden 比對）
```

**依賴紀律**：`magic-validate` 與 `magic-inspect` 依賴 `magic-boundary`，**構不到 `magic-core`、也構不到任何渲染器**——與 demo 執行檔同一條紀律，由 `test/BoundarySpec.hs` 守護。`magic-schema` 更嚴：**它不依賴這個庫的任何部分**。

兩支施法的 CLI 共用 `Validate.defaultContext` 與 `lifetimeOf`——兩個工具報告的是同一次施法，保證這件事的方式是只有一份定義。

## 使用的技術

| 選型 | 理由 |
|---|---|
| **手寫的 schema 宣告表**，而非從 ADT 反射產生 | 若 schema 從型別自動導出，它與 `Magic.Codec` 會同時對或同時錯，`--check` 就只是重複計算而非驗證。手寫使兩者成為**獨立的兩份**，比對才有意義（func-0024 §7-5） |
| **自帶 draft-07 子集驗證器** | 不引入 JSON Schema 執行期依賴；`supportedKeywords` 明列支援範圍，超出即報錯而非默默略過 |
| **GitHub Actions 兩平台矩陣** | private repo 計費、Windows runner 2×，因此閘門設在**併入 main**而非日常 push（ADR-0016 D5） |
| **PVP 上界（`^>=`）** | `magic-core`／`magic-boundary` 是公開 sublibrary，破壞凍結介面＝主版本跳號 |
| **`PM_ABI_VERSION` 與套件版本獨立** | header 只加不改，兩個世代各自移動 |

**一個由 CI 買來的發現**：第一次在 win64 之外跑整套測試時 23 條逐位元 golden 變紅，根因是 libm 的 `sin`／`cos` 相差 1 ulp（IEEE-754 不要求這兩者正確捨入），輸出端絕對差 ≤ `1.79e-07`。ADR-0016 D4 據此把決定論的宣稱從「每個平台」收窄為「同平台逐位元、跨平台結構 ＋ 2 ulp」。**這是那條「只有 win64 實測過」的真正代價，而它只有跑過才看得見。**

## 架構圖

```text
   寫魔法陣的人                                        發布這個庫的人
        |                                                    |
        v                                                    v
+---------------------------------------+   +-------------------------------+
|  magic-validate     magic-inspect     |   |  docs/release.md              |
|   載入/編譯錯誤       法術報告          |   |  CHANGELOG.md                 |
|   --json 批次        （數字全部來自     |   |  particle-magic.cabal metadata|
|                       Magic.Interface）|   |  ADR-0016（相容性政策）        |
+------------------+--------------------+   +---------------+---------------+
                   |                                        |
                   |  依賴 magic-boundary                     |
                   |  （構不到 magic-core、構不到渲染器）        |
                   v                                        |
        +----------------------+                            |
        |  subarch-0004 邊界層  |                            |
        +----------------------+                            |
                                                            |
+---------------------------------------+                   |
|  magic-schema                         |                   |
|   generateSchema（手寫宣告表）          |                   |
|   validateJson（draft-07 子集）        |                   |
|   --check：與committed 檔案 golden 比對 |                   |
|   *** 不依賴這個庫的任何部分 ***         |                   |
+------------------+--------------------+                   |
                   |                                        |
                   v                                        v
   +--------------------------------------------------------------------+
   |                        文字合約（守門測試）                           |
   |                                                                    |
   |  程式碼裡的事實  <==== 測試斷言相等 ====>  文件裡的敘述                 |
   |                                                                    |
   |  SchemaDocSpec / JsonSchemaSpec / ReleaseDocSpec / ReleaseMetaSpec  |
   |  CIWorkflowSpec / ExampleHostSpec / BindingContractSpec             |
   +---------------------------------+----------------------------------+
                                     |
                                     v
                  +---------------------------------------+
                  |  .github/workflows/ci.yml             |
                  |   {windows-latest, ubuntu-latest}     |
                  |   build -> test -> validate           |
                  |   觸發：PR 到 main / v* tag / 手動      |
                  +---------------------------------------+
```

## 資料結構的框架格式

- **驗證報告**：`Report` ＋ `Stats` 的純值，人讀版與 `--json` 版由同一份資料渲染兩次（`renderReport`／`renderJsonReport`），因此兩者不可能不一致。
- **退出碼**：`exitCodeFor` 是純函數，由 `failureCount` 決定——退出碼的語意有測試。
- **Schema**：一份 draft-07 JSON 物件，由 `generateSchema` 產出；另外把「schema 說了什麼」以資料形式外露（`schemaEnumValues`／`keywordsUsedBy`／`refTargets`），作為三方一致律的中間項。
- **換行正規化**：`Schema.normalizeNewlines` 是必需品而非細節——工作樹是 CRLF，任何「產生物 vs 已提交檔案」的比對都要先正規化 `\r`。

## 使用到的套件

| 套件 | 用途 |
|---|---|
| `aeson` | 三支 CLI 的 JSON 讀寫與 schema 產生 |
| `bytestring`／`text`／`vector`／`directory` | 檔案 IO 與批次掃描 |
| `hspec`／`QuickCheck` | 守門測試 |

`magic-schema` 的依賴刻意不含 `particle-magic:*`。

## 開發階段

不屬於主架構的任何一條核心開發鏈——roadmap §4.8 把它畫成「**任何時候，與所有人零交集**」的獨立線，這也是它三次都能插隊平行實作的原因。內部里程碑三個：**M1 作者回饋圈**（寫錯看得到）、**M2 工程化**（CI ＋ 發布政策 ＋ 非 win64 實測）、**M3 機器可讀**（JSON Schema ＋ 檢視器）。三者皆已達成。

## 功能規劃

### 階段一：作者回饋圈（M1，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | authoring-tools | `magic-validate`、`docs/spell-schema.md` 手冊、法術清單熱掃描 | - | func-0014 |

### 階段二：工程化（M2，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 2 | engineering-ci-release | CI 兩平台矩陣、`docs/release.md` ＋ ADR-0016 相容性政策、非 win64 首次實測 | - | func-0019 |

### 階段三：機器可讀（M3，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 3 | authoring-tools-2 | `docs/spell.schema.json` ＋ `magic-schema`、`magic-inspect`、`magic-validate --json`（面板半場見 subarch-0005） | #1 | func-0024 |
| 4 | host-onboarding-docs | `docs/integration.md` 的 Haskell 宿主章節與 2D／像素風食譜（範例半場見 subarch-0004） | #2 | enhance-0001 |

### 階段四：候選（未動工）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 5 | llvm-backend-eval | `-fllvm` 的評估——屬建置環境變數，roadmap 指名與 CI 一起評估（0022 §8-2 記帳） | #2 | - |
| 6 | schema-v2-tooling | schema 版本遞增時的遷移工具與雙版本 golden；與 subarch-0004 #12 同一輪 | #3 | - |
| 7 | visual-editor | 視覺化編輯器／即時預覽 UI——明文「等有非工程作者為止」（0014 §8-1） | #3 | - |
| 8 | unity-manual-checklist | Unity Editor 的「二次 Play」與視覺／GC 觀察：批次模式驗不到，目前是 README 的人眼 checklist（0011 §9.3） | #2 | - |
| 9 | bench-in-ci | 把 `bench` 納入 CI 並設回歸門檻——**本輪新提，尚無既有記帳**；動工前應先在某份 spec 的 §9 立帳 | #2 | - |

**明文不做**：上 Hackage（ADR-0016「被否決」節）。

小結：共 **9 個 features、4 個階段**，前 4 個已交付，作者回饋圈與發布流程都已閉合；階段四五項中 #9 是唯一沒有既有記帳來源的一條，依 roadmap §3 的規矩，它應先立帳再動工。
