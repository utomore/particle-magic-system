---
id: func-0003
type: spec
title: expr-subsystem
description: Expr 數學式子系統本身 —— 封閉一階 AST、全函數求值器、megaparsec 文字語法、渲染器。
status: done
created: 2026-08-12
updated: 2026-08-16
depends-on: [func-0001]
related-adr: [adr-0002, adr-0007]
---

# Func-Spec 0003：Expr 數學式子系統（Expr Subsystem）

> 狀態：已完成（2026-08-12 驗收，見 §10）
> 性質：**重大基建功能** —— 本 spec 定義 DSL 第三層（ADR-0002）的**語言合約**：`Expr` AST 建構子、變數環境、求值語意、文字語法與內建函數集。交付後語言合約即凍結（可擴充 sum 合約見 §4.5）；Expr 符文接線 spec（預定編號 0004）與未來力場/生命週期 spec 皆引用本語言。本 spec 完成驗收前，依賴它的 spec 不得動工。
> 前置依賴：spec 0001（**已完成**，2026-08-12 驗收）。**不依賴 spec 0002**——設計時即與 0002 零共同模組、可平行實作（§0.2 保留作切分依據）；0002 已於 2026-08-12 完成驗收，其凍結介面對本 spec 無影響（0002 不觸碰 `Magic/Expr*`）。
> 依據：[architecture.md](../architecture.md) §4.2、§8（Expr 求值效能的既定延後）、§10；ADR-0002（分層 DSL：封閉、一階、必終止）、ADR-0007（核心零 IO）
> 範圍：Expr 語言本身——數學式 AST、樸素求值器、文字語法剖析（megaparsec）、渲染器。**不含**四種 Expr 符文與魔法陣的接線（spec 0004，見 §9）。

---

## 0. 起點與平行性

### 0.1 引用的 0001 凍結介面

| 介面 | 本 spec 的用法 |
|---|---|
| `hashChan :: Seed -> Int -> Int -> Float`（`Magic.Types`，回傳 [0,1)） | `chan(n)` 變數的**唯一**語意來源——Expr 的隨機性零狀態、bit-for-bit 確定 |
| `Seed`（`Word64` newtype） | `ExprEnv` 攜帶（來自 `CastContext.seed`） |
| `magic-core` 白名單 {base, vector, deepseq} | 本 spec 核心新碼只需 base＋`Magic.Types`——白名單**零增加** |
| `BoundarySpec` 守護 | 凍結合約是前兩條斷言（core 白名單、executable 不依賴 core）；第三條（boundary 依賴清單）是守護測試的參數，本 spec 依規則擴充（§3） |

### 0.2 與 0002 的檔案交集（SKILL.md 規則 4 機械檢查）

| | 0002 觸碰 | 0003 觸碰 |
|---|---|---|
| 模組檔案 | `Magic/Types.hs`、`Magic/Circle.hs`、`Magic/Rune.hs`、`Magic/Compile.hs`、`Magic/Particle/Analytic.hs`、`Magic/Codec.hs`＋其 8 個測試 | `Magic/Expr.hs`（新）、`Magic/Expr/Parse.hs`（新）＋本 spec 5 個測試檔＋`BoundarySpec.hs`（0002 不動它） |
| 模組檔案交集 | **∅** | |
| 共同觸碰 | `particle-magic.cabal`（套件 manifest，非模組檔）——雙方 delta 皆為純加行且落在不同位置，合併機械；本 spec 的 delta 於 §3.1 逐行明列 | |

---

## 1. 目標與完成定義

讓「魔法即數學」有語言：玩家能寫 `sin(t*6.28)*0.5 + chan(0)*0.1` 這樣的公式，系統對**任何**輸入公式保證三件事——**必終止、必回有限值、bit-for-bit 確定**。這是玩家可輸入任意公式而系統不炸的安全線。

完成定義：

1. `parseExpr` 能剖析 §4.4 語法全集；錯誤附行列位置，未知識別字錯誤附合法名稱清單；
2. 任意（QuickCheck 產生的）`Expr` × 任意 env：`evalFinite` 恆回有限 `Float`；同 `(Expr, env)` 兩次求值 bit-for-bit 相等；
3. roundtrip：`parseExpr (renderExpr e) == Right e` 對任意 `Expr` 成立；
4. 節點數 > 512 的公式被剖析層拒絕（載入錯誤，不進核心）；
5. `cabal build all` 與 `cabal test` 全綠（0001 全部回歸；若 0002 已合併，其測試亦不受影響——零共同模組保證）。

---

## 2. 使用到的架構與技巧

| 項目 | 選擇 | 說明 |
|---|---|---|
| 語言邊界即型別事實 | **封閉、一階、固定 arity AST** | 無遞迴定義、無綁定、無使用者函數；`clamp` 三參數是 `Fun3` 建構子而非參數列表——「不合法 arity」不可表示。AST 是有限樹、求值是結構遞迴，**終止性由構造保證**，不是檢查結果 |
| 求值全函數性 | **IEEE 全域求值＋`evalFinite` 消費契約** | `evalExpr` 對任何輸入回值（可為 NaN/±Inf，照 IEEE）；`evalFinite` 把 NaN/±Inf 歸零，是取樣端唯一入口。誠實面對浮點，不在每個運算子塞防禦分支 |
| 隨機性 | **`Chan n` 建構子 → `hashChan`**（0001 凍結機制） | 通道索引限字面整數（§4.4），隨機值 = `hashChan seed pindex n`，零狀態、確定性不破 |
| 剖析 | **megaparsec ＋ parser-combinators 的 `makeExprParser`** | 優先序表宣告式、錯誤訊息含行列位置（`errorBundlePretty`）。boundary 層新依賴，最早暴露 megaparsec × GHC 9.14.1 相容風險 |
| 守門位置 | **剖析層擋掉一切不合法輸入** | 節點數上限、未知名稱、arity 錯誤、`chan` 非字面量參數——全在 boundary 攔截；核心零防禦檢查（同 0002 Codec 的紀律） |
| 求值策略 | **樸素直譯**（`evalExpr` 直接結構遞迴） | 語意最透明、property 最好寫；budgetCap 4096 下無效能壓力。閉包/bytecode 留給效能 spec（architecture.md §8 既定延後）——優化後仍須通過本輪全部 property，語意合約即回歸防線 |
| 可擴充 sum 合約 | **凍結語意、開放建構子**（同 0002 §2） | `Fun1`/`Fun2`/`Fun3`/`BinOp`/`Var` 本輪凍結既有成員的語意與文字名稱，後續以「加建構子＋eval 加 case＋parser 加名稱」擴充，不視為破壞凍結 |
| 測試 | **property 為主**（`Arbitrary Expr` sized 產生器＋shrink） | 全域性質（有限性、確定性、roundtrip）用 property；語意判例與優先序用表格判例 |

---

## 3. 模組變更總覽（delta）

```
src/core/    Magic/Expr.hs        -- 新增：AST、ExprEnv、evalExpr、evalFinite、exprSize（依賴僅 base＋Magic.Types）
src/boundary/Magic/Expr/Parse.hs  -- 新增：parseExpr、renderExpr、ExprParseError、renderExprParseError、maxExprNodes
test/        ExprGen.hs           -- 新增：Arbitrary Expr 產生器（sized＋shrink；非 *Spec 檔，hspec-discover 不撿）
             ExprEvalSpec.hs / ExprParseSpec.hs / ExprRenderSpec.hs / ExprGoldenSpec.hs  -- 新增
             BoundarySpec.hs      -- 修改一行：boundary 允許清單 += megaparsec, parser-combinators
```

### 3.1 `particle-magic.cabal` 純加行 delta（明列供與 0002 機械合併）

| stanza | 欄位 | 加入 |
|---|---|---|
| `library magic-core` | `exposed-modules` | `Magic.Expr` |
| `library magic-boundary` | `exposed-modules` | `Magic.Expr.Parse` |
| `library magic-boundary` | `build-depends` | `megaparsec`、`parser-combinators` |
| `test-suite spec` | `other-modules` | `ExprGen`、`ExprEvalSpec`、`ExprParseSpec`、`ExprRenderSpec`、`ExprGoldenSpec` |
| `test-suite spec` | `build-depends` | `text`（建構 `parseExpr` 的 `Text` 輸入；boundary 已有） |

`magic-core` 的 build-depends **零變更**。`test/Spec.hs` 是 hspec-discover，不需修改。

---

## 4. ADT（語言定義——凍結合約）

### 4.1 `Magic.Expr` AST（永久；可擴充 sum）

```haskell
data Expr
  = Lit  !Float                    -- 字面量
  | Var  !Var                      -- 環境變數
  | Chan !Int                      -- 隨機通道 n：hashChan seed pindex n ∈ [0,1)
  | Neg  Expr                      -- 一元負號
  | Bin  !BinOp Expr Expr
  | Fun1 !Fun1 Expr
  | Fun2 !Fun2 Expr Expr
  | Fun3 !Fun3 Expr Expr Expr
  deriving (Eq, Show)

data Var   = VarT | VarLife | VarPIndex                   deriving (Eq, Show, Enum, Bounded)
data BinOp = Add | Sub | Mul | Div | Pow                  deriving (Eq, Show, Enum, Bounded)
data Fun1  = FSin | FCos | FAbs | FSqrt | FFloor | FSign  deriving (Eq, Show, Enum, Bounded)
data Fun2  = FMin | FMax                                  deriving (Eq, Show, Enum, Bounded)
data Fun3  = FClamp                                       deriving (Eq, Show, Enum, Bounded)
```

### 4.2 環境與求值 API（永久）

```haskell
data ExprEnv = ExprEnv
  { envT      :: !Float   -- 時間（秒，取樣端由 Time/Double 窄化）；預設語意＝施法後秒數，
                          --   呼叫端實際餵入的時間框架由接線 spec 的變數語意表定義（0004 §4.4）
  , envLife   :: !Float   -- 粒子正規化生命 0..1
  , envPIndex :: !Int     -- 粒子索引
  , envSeed   :: !Seed    -- 施法 seed（CastContext.seed）
  }

evalExpr   :: Expr -> ExprEnv -> Float   -- IEEE 全函數：任何輸入必回值（可為 NaN/±Inf）
evalFinite :: Expr -> ExprEnv -> Float   -- 消費端契約：NaN/±Inf → 0；取樣端唯一入口
exprSize   :: Expr -> Int                -- AST 節點數（剖析層上限與測試用）
```

### 4.3 求值語意表（凍結）

| 建構子 | 語意 |
|---|---|
| `Var VarT` / `Var VarLife` | `envT` / `envLife` |
| `Var VarPIndex` | `fromIntegral envPIndex` |
| `Chan n` | `hashChan envSeed envPIndex n`（∈ [0,1)；同 env 恆同值） |
| `Neg` / `Add` / `Sub` / `Mul` | IEEE 標準 |
| `Div` | IEEE：`x/0 = ±Inf`、`0/0 = NaN`（由 `evalFinite` 歸零） |
| `Pow` | Float `**`；負底 × 非整數冪 = NaN（同上歸零） |
| `FSin` / `FCos` / `FAbs` | 標準 |
| `FSqrt` | 負數 → NaN（歸零） |
| `FFloor` | 非有限或 `abs x ≥ 2²³` → 原樣回傳（該域 Float 已無小數部分）；否則 `fromIntegral (floor x :: Int)` |
| `FSign` | `signum`（NaN → NaN） |
| `FClamp x lo hi` | `min (max x lo) hi`（Haskell `min`/`max`：總函數、確定性；NaN 行為由定義展開決定，最終由 `evalFinite` 兜底） |

### 4.4 文字語法（凍結合約；boundary 層）

**詞彙**：
- 變數：`t`、`life`、`pindex`；常數：`pi`（剖析為 `Lit π`）
- 函數：`sin` `cos` `abs` `sqrt` `floor` `sign`（1 參）、`min` `max`（2 參）、`clamp`（3 參：`clamp(x, lo, hi)`）、`chan`（1 參，**限非負整數字面量**——通道索引不可計算，保持確定性推理簡單）
- 數字字面量：十進位整數或小數，可帶 `e` 指數（`1.5`、`3`、`2e-3`）；無前導小數點
- 識別字一律小寫；空白任意

**優先序**（高 → 低）：

| 層 | 內容 |
|---|---|
| 原子 | 字面量、變數、`pi`、函數呼叫 `name(args)`、括號 |
| `^` | 右結合 |
| 一元 `-` | 前綴 |
| `*` `/` | 左結合 |
| `+` `-` | 左結合 |

判例（凍結）：`-x^2 = -(x^2)`；`2^3^2 = 2^(3^2) = 512`；`2^-3` 是**語法錯誤**（指數的負號需括號：`2^(-3)`）。

**守門**：AST 節點數 ≤ `maxExprNodes = 512`（違者剖析錯誤）；未知識別字 → 錯誤附合法名稱清單；arity 不符 → 錯誤附期望參數數；`chan` 參數非「非負整數字面量」→ 錯誤。

**API**：

```haskell
parseExpr            :: Text -> Either ExprParseError Expr
renderExpr           :: Expr -> Text          -- 依優先序最少括號；合約 = roundtrip property（§8 T3）
renderExprParseError :: ExprParseError -> String   -- 含行列位置（errorBundlePretty）
maxExprNodes         :: Int                   -- 512
```

`ExprParseError` 包裝 megaparsec 的 error bundle，對外以 `renderExprParseError` 呈現（同 0001 `renderLoadError` 的模式）；0004 接線時將其嵌入 `LoadError` 既有機制（aeson `Parser` 失敗路徑），不新增 `LoadError` 建構子。

### 4.5 凍結範圍與擴充合約

**凍結**：§4.1 既有建構子的語意（§4.3）與文字名稱/優先序（§4.4）、`ExprEnv` 欄位、`evalFinite` 歸零語意、「`chan` 限字面量」規則。`maxExprNodes` 的**語意**凍結；其值可由後續 spec 上調（放寬非破壞）。

**開放（加建構子式擴充，不視為破壞凍結）**：`Var`/`BinOp`/`Fun1`/`Fun2`/`Fun3` 加成員＋`evalExpr` 加 case＋parser 加名稱；GHC exhaustiveness check 列出所有需補位置。

**預留設計註記**：`ExprV3`（向量式）＝三條 `Expr` 分量（x/y/z 各一），由 spec 0004 隨 `FormulaRune` 定型——本 spec 不定義該型別。

---

## 5. 資料流（pipeline）

```mermaid
flowchart LR
    S["公式字串<br/>（0004 起出現在 circle JSON）"] --> P["parseExpr<br/>megaparsec（純，boundary）"]
    P -->|Left| E["ExprParseError<br/>行列位置＋合法名單"]
    P -->|Right| A["Expr AST<br/>（≤ 512 節點）"]
    A --> C["CompiledSpell 持有<br/>（0004 接線）"]
    C --> Ev["每幀 × 每粒子<br/>evalFinite（純，core）"]
    Ev --> F["有限 Float<br/>→ 取樣管線"]
```

- **剖析是一次性**（載入/熱重載時）；**求值在熱路徑**（每粒子 × 每幀）。本輪樸素直譯在 budgetCap 4096 下無壓力；上到十萬級前由效能 spec 換 staged 求值，本輪的 property 集即其回歸防線。
- IO 分界與 0001/0002 相同：本 spec 所有新碼在純核心／純邊界層，零效果。

---

## 6. 資料結構與儲存方式

| 資料 | 結構 | 存放 | 生命週期 |
|---|---|---|---|
| 公式原文 | `Text`（0004 起在 circle JSON 的符文欄位內） | `assets/spells/*.json`（0004 起） | 使用者編輯；熱重載重剖析 |
| `Expr` | 不可變有限樹 | `CompiledSpell` 內（0004）；本輪僅測試建構 | 編譯期建立，施法期唯讀 |
| `ExprEnv` | 暫態 record | `sample` 呼叫棧（0004） | 單粒子單幀 |
| `ExprParseError` | megaparsec bundle 包裝 | 載入錯誤路徑 | 單次載入 |

---

## 7. 搭建方式（實作順序，風險優先）

| 步驟 | 內容 | 為什麼在這個位置 |
|---|---|---|
| S1 | `Magic.Expr`：AST＋`ExprEnv`＋`evalExpr`/`evalFinite`/`exprSize`；`test/ExprGen.hs` 的 `Arbitrary Expr`（sized＋shrink） | 語意核心先立；`Arbitrary` 產生器是全輪 property 的地基，先寫先受益 |
| S2 | `Magic.Expr.Parse` 剖析器（優先序表、四項守門、錯誤訊息）；cabal §3.1 delta＋`BoundarySpec` 允許清單擴充 | **語法是對外合約，設計錯誤最貴**；新依賴 megaparsec × GHC 9.14.1 的相容風險最早暴露 |
| S3 | `renderExpr` 渲染器 | roundtrip 是語法凍結的機械證明；依賴 S1＋S2 |
| S4 | 黃金判例（典型魔法公式）＋§4.3 語意表互證 | 壓軸：全部就緒後的合成驗收，判例即未來優化的語意基準 |

每步紀律同 0001/0002：**完成一個 Sx ＝ 對應測試 Tx 綠**，不積欠。

---

## 8. Todo List 與 1-to-1 測試對應

| ✅ | Todo | 測試（`test/` 下） | 測試內容（完成即斷言） |
|---|---|---|---|
| ✅ | **S1** AST 與求值器 | `ExprEvalSpec.hs` | 代數判例（加乘單位元、`Neg . Neg == id` 語意）；三變數查值；`Chan n` 求值 == `hashChan seed pindex n`（property）；同 `(Expr, env)` 兩次求值 bit-for-bit 相等（property）；任意 `Expr` × 任意 env → `evalFinite` 恆有限（property，含刻意生成 `Div`/`Pow`/`FSqrt` 的 NaN/Inf 路徑）；`exprSize` 判例；數百節點深樹求值完成 |
| ✅ | **S2** 剖析器與守門 | `ExprParseSpec.hs` | §4.4 三判例（`-x^2`、`2^3^2`、`2^-3` 錯誤）＋優先序/結合性判例表；空白容忍；未知識別字 → 錯誤含位置與合法名單；`sin(1,2)` arity 錯誤；`chan(t)`、`chan(-1)` → 錯誤；> 512 節點 → 錯誤；`BoundarySpec` 擴充後三斷言仍綠 |
| ✅ | **S3** 渲染器 | `ExprRenderSpec.hs` | roundtrip property：`parseExpr (renderExpr e) == Right e`（任意 `Expr`）；抽查判例：render 輸出最少括號且可讀（如 `Bin Add (Bin Mul …) …` → `a*b + c`） |
| ✅ | **S4** 語意黃金判例 | `ExprGoldenSpec.hs` | 典型公式在固定 env 取樣點的期望值（誤差 1e-5）：脈衝 `abs(sin(t*pi))`、衰減 `(1 - life)^2`、每粒子相位 `sin(t*6.0 + chan(0)*6.28318)`、`clamp` 邊界值；黃金判例同時驗證 §4.3 語意表與實作一致 |

規則同前：**一個 Todo 打勾的前提是對應測試存在且綠**。0001 既有十個測試模組是回歸防線，全程必須保持綠（本 spec 與 0002 零共同模組，互不影響對方回歸）。

---

## 9. 非目標（本 spec 明確不做）

- **四種 Expr 符文**（`RangeRune`/`ConvergeRune`/`AmplifyRune`/`FormulaRune`）與 `Circle`/fold/Codec 的接線、`ExprV3` 定型、公式字串進 circle JSON schema —— **spec 0004**（前置依賴：0002 與 0003 皆已完成）
- 閉包/bytecode/staged 求值優化 —— 效能 spec；本輪 property 集是其語意回歸防線
- 使用者自訂函數、綁定（let）、遞迴、條件分支 —— ADR-0002 的語言邊界，**永不做**（條件需求以 `clamp`/`sign`/`abs` 組合表達）
- 求值時間預算等進一步資源治理 —— 節點上限 × 無迴圈已界定單次求值成本上界
- `Double` 精度求值 —— 粒子資料全為 `Float`（0001 SoA），Expr 統一 `Float`

## 10. 驗收紀錄（實作時回填）

| 項目 | 日期 | 結果 |
|---|---|---|
| `cabal test` 全綠（0001 回歸＋本 spec 四個測試模組） | 2026-08-12 | ✅ 204 examples, 0 failures（全套件，含 0001/0002 回歸）；本 spec 四模組：ExprEvalSpec 27、ExprParseSpec 29、ExprRenderSpec 11（roundtrip property 1000 例）、ExprGoldenSpec 23；`cabal build all` 亦綠 |
| `BoundarySpec` 擴充後三斷言綠（megaparsec 只進 boundary） | 2026-08-12 | ✅ 三斷言綠；megaparsec、parser-combinators 僅入 `magic-boundary`；`magic-core` build-depends 零變更（白名單 {base, vector, deepseq} 不動） |
| megaparsec × GHC 9.14.1 × Windows 實際版本紀錄 | 2026-08-12 | megaparsec **9.8.1** × parser-combinators **1.3.1** × GHC 9.14.1 × Windows 11——直接解依賴成功，**無需 allow-newer** |
| 凍結的介面清單（重大基建交付必填：實際凍結的 AST 建構子語意、文字語法詞彙/優先序、`ExprEnv` 欄位、API 簽名，供 0004 引用） | 2026-08-12 | 見下方清單 |

**凍結的介面清單**（0004 起引用；擴充僅依 §4.5 加建構子式）：

- `Magic.Expr`（core）：`Expr(..)`（`Lit`／`Var`／`Chan`／`Neg`／`Bin`／`Fun1`／`Fun2`／`Fun3`）、`Var(..)`、`BinOp(..)`、`Fun1(..)`、`Fun2(..)`、`Fun3(..)`，語意如 §4.3（含 `FFloor` 的 2²³ 規則、`Chan n` = `hashChan envSeed envPIndex n`）；`ExprEnv(envT, envLife, envPIndex, envSeed)`；`evalExpr :: Expr -> ExprEnv -> Float`（IEEE 全函數）、`evalFinite :: Expr -> ExprEnv -> Float`（NaN/±Inf → 0，取樣端唯一入口）、`exprSize :: Expr -> Int`
- `Magic.Expr.Parse`（boundary）：`parseExpr :: Text -> Either ExprParseError Expr`、`renderExpr :: Expr -> Text`（合約＝roundtrip property）、`renderExprParseError :: ExprParseError -> String`（含行列位置）、`maxExprNodes = 512`（語意凍結，值可由後續 spec 上調）
- 文字語法：§4.4 詞彙（`t`／`life`／`pindex`／`pi`；`sin` `cos` `abs` `sqrt` `floor` `sign`｜`min` `max`｜`clamp`｜`chan` 限非負整數字面量）與優先序表（原子 > `^` 右結合 > 一元 `-` > `*` `/` 左 > `+` `-` 左）；判例 `-x^2 = -(x^2)`、`2^3^2 = 512`、`2^-3` 語法錯誤——已由 ExprParseSpec／ExprRenderSpec 機械證明
