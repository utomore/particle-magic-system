---
id: adr-0006
type: adr
title: soa-unboxed-buffer
description: 粒子緩衝採 SoA 加 unboxed vector
status: accepted
created: 2026-08-11
updated: 2026-08-16
related-adr: [adr-0009, adr-0018]
related-spec: [func-0023]
---

# ADR-0006：SoA + Unboxed Vector 粒子緩衝

- 狀態：已採納（2026-08-11）；**六欄佈局於 2026-08-16 由 [ADR-0018](adr-0018-custom-shader-and-columns.md) D2 鬆綁為九欄——以「加欄＋新查詢函數」而非「改既有簽名」的方式，見文末**
- 相關：[architecture.md §4.5, §7](../architecture.md)

## 背景

效能目標為單場景 1 萬～10 萬粒子。Haskell 的預設資料表示（boxed、lazy、指標密集）在這個量級的每幀運算下，快取失誤與 GC 壓力都會成為瓶頸。Init.md 已預想「dense grid, SoA + Unboxed Vector」方向。

## 決策

粒子緩衝採 **Structure of Arrays（SoA）＋ `Data.Vector.Unboxed`**：

```haskell
data ParticleBuffer = ParticleBuffer
  { pbPosX, pbPosY, pbPosZ :: !(U.Vector Float)
  , pbSize, pbLife         :: !(U.Vector Float)
  , pbColor                :: !(U.Vector Word32)
  -- 2026-08-16（func-spec 0023／ADR-0018 D2）加三欄，opt-in（空 = 未計算）：
  , pbVelX, pbVelY, pbVelZ :: !(U.Vector Float)
  , pbCount                :: !Int
  }
```

配套策略：緩衝以編譯期算出的 `ParticleBudget` 一次配足並逐幀重用（內部以 `ST` mutable 寫入，對外介面仍純）；緩衝可經 `unsafeWith` 以指標直傳 FFI 給 raylib instanced 繪製。

## 後果

**正面**：

- 熱路徑（取樣、力場步進）是連續記憶體上的緊密迴圈：無 box、無指標追蹤、快取行利用率高，GHC 可有效 unbox/fuse。
- GC 只見少數大型陣列而非十萬個小物件，minor GC 壓力趨近於零（配合緩衝重用）。
- SoA 各欄位獨立成陣列，恰好對應 instanced rendering 的 per-instance attribute 佈局，FFI 零轉換。
  ——**由 [ADR-0009](adr-0009-dynamic-quad-mesh-rendering.md) 修訂**：渲染路徑實際採動態 quad mesh（instancing 經實證否決），每幀有一次 O(n) 的 CPU quad 展開；「零轉換」不再成立，但每幀 FFI 次數仍為 O(1)。

**負面**：

- **欄位佈局成為硬點**：加一個粒子屬性＝改 `ParticleBuffer`、取樣器、FFI 佈局三處（見 architecture.md §11）。
  ——**2026-08-16（func-spec 0023、[ADR-0018](adr-0018-custom-shader-and-columns.md) D2）第一次真的加欄**：六欄 → 九欄（`pbVelX/Y/Z`）。硬點沒有消失，但走出了一條**可重複的路**，記在下面。
- Unboxed 表示排除了 sum type 欄位；粒子的異質行為必須用發射器層級區分（同一發射器內粒子同質），這是模型上的約束。
- 內部 mutable 寫入需要紀律（`ST` 封裝、不逃逸），比全 immutable 實作多一類潛在錯誤。

## 欄位佈局的鬆綁方式（2026-08-16，func-spec 0023 ／ ADR-0018 D2）

**現行佈局為九欄**：`pbPosX/Y/Z`、`pbSize`、`pbLife`、`pbColor`、`pbVelX/Y/Z`、`pbCount`。前六欄的名稱、型別、順序、語意**逐位元不變**。

鬆綁的**方式**才是這一節要留下來的東西——日後真的必須再加欄時照抄：

| 依賴方 | 作法 | 反面（沒做的事） |
|---|---|---|
| 熱路徑 | **opt-in**：不需要新欄的魔法讓它是空向量，`sample` 在**進迴圈前**選一次建構子（`buildBuffer` vs `buildBufferWithVelocity`），逐粒子迴圈一條指令都不多 | 不是「多算了但便宜」，是**結構性跳過**——比照 ADR-0010 D9 的零場快路徑 |
| 不變量 | `bufferInvariant` 加一條：新欄長度 ∈ {0, `pbCount`}，且同組欄位同步 | 不讓「可能有可能沒有」散成每個消費者各自的 `if`；問一次 `hasVelocity` 就夠 |
| FFI | **加新進入點**（`pm_observe_ex`），舊的一字不動、且實作上降級為新的一個特例 | 不改 `pm_observe` 的簽名——既有宿主零重編譯（ADR-0011 D7） |
| 邊界層 | **加新函數**（`fromColumnsWithVelocity`），`fromColumns` 簽名不變 | 同上 |
| 渲染後端 | 只有真的要用的 batch 讀新欄，其餘走既有展開 | — |

**但書：這不表示以後加欄變便宜了。** 上表每一列都要重付一次，而 0023 之所以付得起，有一半是運氣——`BillboardTrail` 需要的速度欄**恰好**同時消掉了 ADR-0013 D1（帶參數 billboard 撞上 `PM_BATCH_INFO_STRIDE`）那筆欠款，一份代價結清兩件事。下一輪不會剛好又這樣。

**實測代價**（同機、與交付前的 build 逐一對照，見 func-spec 0023 §9.3）：無新欄的取樣**沒有變慢**（實測反而快約 1.6×，是 opt-in hook 所需的 `INLINE` 重構帶來的編譯結果差異，輸出逐位元不變）；真的要速度的魔法付 **2.3×**——那是有限差分的定義代價（每顆粒子多跑一次完整位置公式），不是加欄本身的代價。

## 被否決的替代方案

- **Boxed list / `Data.Vector`（AoS）**：實作最自然，千級粒子可用，但十萬級下 GC 與快取行為不可接受；且之後換 SoA 會動到核心取樣介面——不如第一天就用對。
- **`Storable` Vector / 手動 `Ptr` 管理**：FFI 更直接，但把 C 式記憶體管理引入純核心，喪失 unboxed vector 的 fusion 與安全性；`U.Vector` 已可 `unsafeWith` 直傳指標，足夠。
- **GPU 常駐粒子（compute shader）**：百萬級才需要；引入後核心輸出從「粒子資料」變成「shader 參數」，架構完全不同，且 h-raylib 的 compute 支援面不明。明確列為非目標。
