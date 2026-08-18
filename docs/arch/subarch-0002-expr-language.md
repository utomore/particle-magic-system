---
id: subarch-0002
type: subarch
title: expr-language
description: 玩家可寫的小型算式語言：AST、求值器與文字文法
status: active
created: 2026-08-18
updated: 2026-08-18
parent-arch: architecture
related-adr: [adr-0002, adr-0005]
---

# 數學式 Expr 子系統架構

## 定位與範圍

[主架構 §2.1](architecture.md#21-子系統劃分) 六塊裡唯一的**縱切**子系統：同一個語言的 AST 與求值器住純核心，文字文法住邊界層。這個切法不是妥協，是 ADR-0002 與主架構 §2 關鍵約束的直接後果——**核心只認識 AST，不認識文字**。玩家在 JSON 裡寫 `"sin(t*6)*0.3"`，那串文字在邊界層就被轉成 `Expr`，核心一個字元都沒看到。

Expr 是三層 DSL 的第三層（ADR-0002：circle 結構 ADT ＋ 參數 record ＋ 小型算式 AST），也是整個系統唯一**由玩家直接撰寫程式碼**的地方。因此它同時是表達力來源與攻擊面。

**做**：

- `Expr` AST 的定義、語意與求值（參照實作 `evalExpr`）
- 編譯期化簡：常數摺疊、共同子式消去、扁平 bytecode
- 文字文法的剖析（含錯誤位置）與反向還原
- 確定性隨機通道 `chan(n)` 的求值語意

**明確不做**：

- **不決定式子掛在哪個槽位、吃哪一條時間軸**。`t` 在行為層是粒子年齡、在調變層是施法秒數——這條分層是 [subarch-0001](subarch-0001-magic-semantics.md) 的語意，本子系統只提供 `VarT` 這個變數與一個 `ExprEnv`。
- **不是 λ 演算**。封閉、一階、無遞迴綁定、無使用者定義函數。這保證求值必然終止、可序列化、可做靜態區間分析。
- **不做浮點例外處理**。求值是 IEEE-total 的：除以零得 `Infinity`，不拋例外；把非有限值擋在外面是消費端 `evalFinite` 的責任。

## 需求說明

1. **玩家寫得出來**：文法要小到可以寫進一頁文件，錯誤訊息要附行列位置（架構 §9.5 明列「錯誤訊息品質玩家會直接面對」）。
2. **求值必然終止且零狀態**：隨機性以 `Chan Int` 注入，值由 `(Seed, 粒子索引, 通道)` 雜湊導出——確定性與可重播性不能被隨機性破壞。
3. **熱路徑要快，但語意不能因為變快而改變**。加速手段一律以**等價律**綁住：優化後的求值器與 `evalExpr` 必須逐位元相同。
4. **只加不改**：玩家的式子存在 JSON 裡，改既有運算子的語意會靜默改變舊魔法的行為（主架構 §11）。

## 架構規劃

| 元件 | 檔案 | 層 | 職責 |
|---|---|---|---|
| AST 與參照求值器 | `src/core/Magic/Expr.hs` | 核心 | `Expr`／`Var`／`BinOp`／`Fun1..3`／`ExprV3`、`ExprEnv`、`evalExpr`（**語意的單一事實來源**）、`evalFinite`／`evalFiniteV3`、`exprSize`、`foldConstants` |
| 編譯後的程式 | `src/core/Magic/Expr/Code.hs` | 核心 | `ExprCode`／`ExprCodeV3` 扁平指令陣列、`compileExpr`、`evalCode`；hash-consing 的 `ExprDag`／`cse`。熱路徑走這裡 |
| 文字文法 | `src/boundary/Magic/Expr/Parse.hs` | 邊界 | `parseExpr`（megaparsec，錯誤附位置）、`renderExpr`（AST → 文字）、`maxExprNodes` 節點數上限 |

**為什麼 `Expr.hs` 在 0022 之後一個字都沒改**：bytecode 這一階被刻意設計成「加一個模組，不動舊模組」。`evalExpr` 從熱路徑降級為**等價律的參照實作**——它現在的主要用途是在測試裡當被比對的那一半。主架構 §8.2 那句「AST 介面不變，只換求值器」被做到字面上。

## 對外介面

```haskell
-- 邊界層（消費者：Magic.Codec、作者工具）
parseExpr             :: Text -> Either ExprParseError Expr
renderExpr            :: Expr -> Text                 -- 往返律：parseExpr . renderExpr ≡ Right
renderExprParseError  :: ExprParseError -> String     -- 附行列位置
maxExprNodes          :: Int                          -- 剖析期節點上限（輸入面護欄）

-- 核心：語意（消費者：測試、subarch-0001 的區間算術）
evalExpr      :: Expr -> ExprEnv -> Float             -- 全函數，IEEE-total
evalFinite    :: Expr -> ExprEnv -> Float             -- 保證有限值
foldConstants :: Expr -> Expr                         -- 律：evalExpr . foldConstants ≡ evalExpr

-- 核心：熱路徑（消費者：subarch-0003 的取樣器）
compileExpr       :: Expr -> ExprCode                 -- 律：evalCode . compileExpr ≡ evalExpr（逐位元）
evalCode          :: ExprCode -> ExprEnv -> Float
evalCodeFiniteV3  :: ExprCodeV3 -> ExprEnv -> V3
cse               :: [Expr] -> ExprDag                -- 共同子式消去
```

**凍結的文法**（spec 0003 起未變）：實數、常數 `pi`、變數 `t`／`life`／`pindex`、隨機通道 `chan(n)`、運算子 `+ - * / ^`、函數 `sin cos abs sqrt floor sign min max clamp`、括號。

**兩條等價律**是本子系統對外的核心承諾，也是它敢於重寫求值器的唯一理由：

| 律 | 內容 | 守護 |
|---|---|---|
| 摺疊律 | `evalExpr (foldConstants e) env ≡ evalExpr e env`，逐位元 | `test/ExprFoldSpec.hs` |
| 編譯律 | `evalCode (compileExpr e) env ≡ evalExpr e env`，逐位元 | `test/ExprCodeSpec.hs`、`ExprCseSpec.hs` |

## 使用的技術

核心半場沿用主架構的技術棧且零額外依賴。邊界半場特有的選型是 **megaparsec ＋ parser-combinators**：主架構 §9.5 選它的理由是錯誤位置回報，這也是唯一被玩家直接看見的錯誤訊息來源。

化簡策略的取捨（實測結論，spec 0022 §9）：**熱點不在 Expr**。重複子式多的式子走 bytecode 快 1.57×，但已出貨的三張帶公式範例陣整體取樣時間只在 −12% 到 +2% 之間，即打平。這一階梯的價值在於**它隨式子複雜度成長**（193 節點的深式子 CSE 砍掉 33% 節點），而玩家的式子只會愈寫愈長。

## 架構圖

```text
  JSON 裡的字串  "sin(t*6)*0.3"
        |
        |  邊界層（magic-boundary）
        v
  +-------------------------------------------+
  | Magic.Expr.Parse                          |
  |   parseExpr  ---> Expr   （錯誤附行列）    |
  |   renderExpr <--- Expr   （往返律）        |
  |   maxExprNodes：節點數上限，輸入面護欄      |
  +---------------------+---------------------+
                        |  Expr（純資料，可序列化）
========================|=================================
                        |  核心層（magic-core，零 IO）
                        v
  +-------------------------------------------+
  | Magic.Expr                                |
  |   Expr / Var / BinOp / Fun1..3 / ExprV3   |
  |   evalExpr    <-- 語意的單一事實來源        |
  |   foldConstants（常數摺疊）                 |
  +---------------------+---------------------+
                        |  摺疊律
                        v
  +-------------------------------------------+
  | Magic.Expr.Code                           |
  |   cse -> ExprDag  （hash-consing 去重）    |
  |   compileExpr -> ExprCode（扁平指令陣列）   |
  |   evalCode                                |
  +---------------------+---------------------+
                        |  編譯律（逐位元 ≡ evalExpr）
                        v
        subarch-0003 的取樣熱路徑（每粒子每幀求值）

  掛載點由 subarch-0001 決定：
    行為層的式子 -> t = 粒子年齡
    調變層的式子 -> t = 施法秒數
```

## 資料結構的框架格式

- **AST**：封閉 sum type，建構子欄位一律 strict（`Lit !Float`、`Bin !BinOp`）。`ExprV3` 是三個 `Expr` 的並排，不是向量原生型別——向量運算目前在解釋器層而非式子層。
- **求值環境**：`ExprEnv` 是一個小 record（`t`／`life`／`pindex`／`seed`／粒子索引），逐粒子建構，不含任何可變狀態。
- **DAG**：`cse` 產出 `ExprDag`（節點陣列 ＋ 以結構為鍵的 hash 桶），同一棵子樹只保留一份。
- **Bytecode**：`ExprCode` 是扁平的指令陣列 ＋ 常數池，求值以固定大小的堆疊在緊密迴圈中走完，**每指令零配置**（由 `test/ExprCodeSpec.hs` 讀 RTS 配置計數器斷言）。

## 使用到的套件

| 套件 | 層 | 用途 |
|---|---|---|
| `base` | 核心＋邊界 | — |
| `megaparsec` | 邊界 | 文字文法剖析，錯誤位置 |
| `parser-combinators` | 邊界 | 運算子優先序表 |
| `text` | 邊界 | 輸入字串 |

核心半場**零額外依賴**——AST、化簡與 bytecode 全部只用 `base`。

## 開發階段

對應主架構的 POC 實作階段。內部里程碑兩個：**M1 語言可用**（玩家寫得出式子、系統算得出值），**M2 語言夠快**（三階加速梯全數落地且逐位元等價）。兩者皆已達成，且 M2 的實測結論反而是「熱點不在這裡」——這個結論本身是本子系統對後續效能工作的最大貢獻。

## 功能規劃

一份 spec 只掛在一個子系統（`/code-audit status` 以此判定歸屬與進度），所以下表只列**主場在本子系統**的 spec；橫跨到別處的那一半記在表後的參與清單。

### 階段一：語言可用（M1，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 1 | expr-subsystem | AST、`evalExpr`、文字文法剖析與還原，文法凍結 | - | func-0003 |

### 階段二：語言夠快（M2，已交付）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 2 | cse-and-bytecode | hash-consing 共同子式消去 ＋ 扁平 `ExprCode`；編譯律逐位元，`Expr.hs` 零觸碰 | #1 | func-0022 |

### 階段三：候選（未動工）

| # | feature | 一句話說明 | 依賴 | spec |
|---|---------|-----------|------|------|
| 3 | expr-error-quality | 剖析錯誤訊息的玩家可讀性——目前有位置但沒有建議（主架構 §9.5 記帳） | #1 | - |
| 4 | expr-vector-ops | 向量層級的運算子與函數，讓 `ExprV3` 不只是三個並排的純量式（主架構 §10 擴充點） | #1 | - |
| 5 | expr-static-feedback | 把 `evalInterval` 的靜態範圍分析回饋給作者工具，讓寫式子的人在存檔前看到界（現僅供 `emitterBounds` 內部使用） | #2 | - |
| 6 | expr-fourth-time-mount | 第四種時間掛載點的求值環境（時變場參數／非等速自轉）；與 subarch-0001 #11 同一輪 | #1 | - |

**本子系統參與但不擁有的 spec**

| spec | 主場 | 本子系統的那一半 |
|---|---|---|
| func-0004 | [subarch-0001](subarch-0001-magic-semantics.md) | 四種夾帶式子的符文接線，以及「行為層 `t`＝粒子年齡、調變層 `t`＝施法秒數」這條分層時間軸的語言半場 |
| func-0010 | [subarch-0003](subarch-0003-particle-simulation.md) | `foldConstants` 編譯期常數摺疊——三階加速梯的第一階，摺疊律逐位元 |

小結：共 **6 個 features、3 個階段**，前 2 個已交付，語言本身已凍結且夠快；階段三四項皆為擴充而非修補。**擁有的 spec 只有兩份，但參與的有四份**——這正是一個縱切子系統該有的形狀：它的程式碼被每一輪動到，主場卻多半在別人那裡。
