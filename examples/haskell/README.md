# examples/haskell — 最小 Haskell 宿主

`examples/c/main.c` 的母語版本，職責一模一樣：**做遊戲引擎會做的事，扣掉畫圖**。載入一張魔法陣、施法、跑 120 個固定時步的 `advance` + `observe`，一顆頂點都不送 GPU，改成每幀印一行。

它存在的理由：在 enhance-0001 之前，三種消費模式裡**只有母語那一條沒有可跑的證明**——C 有 `examples/c/`、C# 有 `examples/unity/`，而 Haskell 只有 `docs/integration.md` 裡的片段，沒有任何東西編譯它、沒有任何東西測試它。

---

## 建置與執行

這是一個**獨立的 cabal package**，不是根專案的一個 stanza。根目錄的 `cabal build all` **不會**涵蓋它——這正是重點：stanza 編得起來，但它從來沒有走過一次外部消費者走的路。代價是要多下一行指令，與 `examples/c/main.c` 需要另外 `gcc` 一次同款。

```bash
cd examples/haskell
cabal run pm-haskell-host
cabal run pm-haskell-host -- ../../assets/spells/spiral-spark.json
```

`cabal.project` 用**相對路徑**指回 `../..`，所以一份乾淨的 checkout 不必連網、不必有已發布的 tag 就能跑。真實宿主改寫成下面這段即可，本 package 其他地方一個字都不用動：

```cabal
source-repository-package
  type:     git
  location: https://github.com/utomore/particle-magic-system.git
  tag:      <commit-or-tag>
```

## smoke：一行 diff

預期輸出凍結在 `expected-output.txt`：

```bash
cabal run -v0 pm-haskell-host | diff - expected-output.txt
```

`test/ExampleHostSpec.hs`（根專案的測試套件）用**兩條各自獨立的路徑**重算同一批數字並比對這個檔案——一條走 `Magic.Interface`，一條走 C ABI（in-process，比照 `examples/c/main.c` 的呼叫序）。所以這份 golden 不是某次隨手存下的快照，而是 `cabal test` 每次都在守的東西。

## 這個範例證明了什麼

| | |
|---|---|
| **外部專案接得上** | 依賴 `particle-magic:magic-boundary`，碰不到 `magic-core`，不連任何 renderer |
| **合約就是那三個模組** | `Magic.Codec`、`Magic.Interface`、`Magic.Projection`——integration.md §3 的清單，一個不多 |
| **兩條路徑是同一個模擬** | 同一組輸入下，Haskell 路徑與 C ABI 路徑的每幀數值相同 |
| **2D 用得上** | 結尾印出最後一幀在 `SideXY` 與 `TopXZ` 兩個平面的正交投影與 painter 順序 |

## 依賴面：四個，不是兩個

`build-depends` 除了 `base` 與 `particle-magic:magic-boundary`，還有兩個容易漏掉的：

- **`bytestring`** — `loadCircle` 吃的是檔案的原始位元組（編碼是宿主的事，不是庫的）。
- **`vector`** — `ParticleBuffer` 是 `Data.Vector.Unboxed` 上的 SoA（ADR-0006）。任何要讀那六條欄的宿主都需要它。

## 一個會咬人的細節：`dt` 的寬度

`simDt` 用的是 **`1/60 :: Float` 最接近的 double**，不是 `1/60 :: Double`。

因為 C ABI 的 `pm_advance` 收的是 `float`，進來之後才加寬成 double。所以一個在自己原始碼裡寫 `1.0f/60.0f` 的 C 宿主，和一個寫 `1/60` 的 Haskell 宿主，**跑的不是同一個模擬**。決定論是「同一組輸入 → 逐位元相同」（ADR-0011 D8），而 `dt` 是輸入之一。

本範例刻意收窄，好讓它的逐幀摘要能直接跟 `examples/c/main.c` 的對 diff。你自己的 Haskell 宿主沒有這個義務——除非你也要跟 C 宿主對答案。

## 施法者面向與 2D 視角

範例沿用 C 宿主的 `casterFacing = V3 0 0 1`（為了可對比）。**這對俯視（`TopXZ`）宿主是錯的示範**：初始面垂直於 facing、立體擴充沿 facing 前進，facing 落在被丟掉的那一軸上時，整根光柱會塌成它自己的足跡——不會報錯，只是看起來「怪但說不出哪裡怪」。

選法的完整對照表在 [`docs/integration.md` §3.3](../../docs/integration.md)。
