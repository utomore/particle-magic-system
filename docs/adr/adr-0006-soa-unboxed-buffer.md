---
id: adr-0006
type: adr
title: soa-unboxed-buffer
description: 粒子緩衝採 SoA ＋ unboxed vector,目標量級 10k–100k。
status: accepted
created: 2026-08-11
updated: 2026-08-16
related-adr: [adr-0009]
related-spec: []
---

# ADR-0006：SoA + Unboxed Vector 粒子緩衝

- 狀態：已採納（2026-08-11）
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
- Unboxed 表示排除了 sum type 欄位；粒子的異質行為必須用發射器層級區分（同一發射器內粒子同質），這是模型上的約束。
- 內部 mutable 寫入需要紀律（`ST` 封裝、不逃逸），比全 immutable 實作多一類潛在錯誤。

## 被否決的替代方案

- **Boxed list / `Data.Vector`（AoS）**：實作最自然，千級粒子可用，但十萬級下 GC 與快取行為不可接受；且之後換 SoA 會動到核心取樣介面——不如第一天就用對。
- **`Storable` Vector / 手動 `Ptr` 管理**：FFI 更直接，但把 C 式記憶體管理引入純核心，喪失 unboxed vector 的 fusion 與安全性；`U.Vector` 已可 `unsafeWith` 直傳指標，足夠。
- **GPU 常駐粒子（compute shader）**：百萬級才需要；引入後核心輸出從「粒子資料」變成「shader 參數」，架構完全不同，且 h-raylib 的 compute 支援面不明。明確列為非目標。
