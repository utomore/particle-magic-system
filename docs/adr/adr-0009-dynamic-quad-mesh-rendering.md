---
id: adr-0009
type: adr
title: dynamic-quad-mesh-rendering
status: accepted
created: 2026-08-13
updated: 2026-08-13
related-adr: [adr-0006]
related-spec: [func-0005]
---

# ADR-0009：渲染路徑採動態 quad mesh，不採 instancing

- 狀態：已採納（2026-08-13）
- 相關：[architecture.md §7, §9.2](../architecture.md)、[ADR-0006](adr-0006-soa-unboxed-buffer.md)（本 ADR 修訂其「FFI 零轉換」宣稱）、[func-spec 0005 §0.2](../spec/func-0005-render-observability.md)（實證調查紀錄）
- 附註：本決策依據 h-raylib 5.6.0.0 **原始碼閱讀**結論；待 func-spec 0005 的 S0 spike 實機確認。若 spike 觸發 0005 §7 的備案階梯（每幀 uploadMesh 重建 → 逐粒子 drawBillboard → instancing＋內嵌 GLSL），本 ADR 狀態欄回填修訂。

## 背景

architecture.md §7 原規劃「Instanced rendering：raylib 端以單一 quad mesh ＋ per-instance 位置/顏色/尺寸繪製整個 batch」，§9.2 將 h-raylib 的 instancing 支援面列為開放技術困難。func-spec 0005 設計期讀 h-raylib 5.6.0.0 原始碼（cabal 套件快取）得到三項實證：

1. **所有 FFI 綁定皆為 `ccall safe`**（TH 產生器 `Raylib.Internal.TH` 統一宣告），每呼叫約百 ns 級開銷——任何「逐粒子呼叫」路線（`drawCubeV`、`drawBillboard`、rlgl 逐頂點）都不可規模化。
2. **`drawMeshInstanced` 的綁定吃 `[Matrix]`**：每幀對 4096 粒逐元素 marshal 16 個 float；且 raylib C 端要求 material 掛**自訂 instancing shader**（預設 shader 無 `instanceTransform` attribute）。
3. **instancing 無 per-instance 顏色槽**：每 instance 只有 transform——`ColorRamp` 的逐粒子顏色會丟失，直接牴觸「特效即魔法」（元素顏色是語意）。

## 決策

渲染路徑採**動態 quad mesh ＋ `c'` 指標 API**：

- 初始化一次：`uploadMesh mesh True`（dynamic mesh，容量 = `budgetCap` × 4 頂點）；索引緩衝以 `Word16` 寫死每 quad `0,1,2, 0,2,3` 模式（4096×4 = 16384 < 65536）。
- 每幀 O(1) 次 FFI：`Data.Vector.Storable.unsafeWith` 餵 `c'updateMeshBuffer`（positions／colors 兩條 VBO，零拷貝）→ poke `p'mesh'triangleCount`（變長繪製）→ `c'drawMesh :: Ptr Mesh -> Ptr Material -> Ptr Matrix -> IO ()`。
- billboard 面向相機由 CPU 端純函數（`buildQuads`）以相機基底展開 quad——headless 可測。
- 頂點色走 raylib **預設 shader**（quad 四頂點同色＝逐粒子顏色），免自訂 shader。

官方 `examples/bunnymark` 明文背書 `c'` 前綴指標慣用法（"Writing performant h-raylib code requires the use of pointers"）。

## 後果

**正面**：

- architecture §7「draw call 數 = batch 數而非粒子數」的承諾保持兌現。
- 逐粒子顏色保留；零 shader 維護成本；每幀 FFI 次數 ~4。
- 未來 10k–100k 效能 spec 只需替換 CPU 端 staging 填充策略（緩衝重用、平行填充），GPU 路徑不動。

**負面**：

- **修訂 ADR-0006 的「FFI 零轉換」宣稱**：SoA 欄位不再直傳——每幀需一次 O(n) 的 CPU quad 展開（`buildQuads`：SoA → 4 頂點/粒子的 Storable 串流）。此展開是純函數且可基準量測（0005 S8），成本已知且可控。
- 頂點資料量是 instancing 的 4 倍（每粒子 4 頂點而非 1 個 transform）；在 `budgetCap = 4096` 下不構成頻寬問題，100k 級時由效能 spec 重新評估。

## 被否決的替代方案

- **`drawMeshInstanced`**：背景節三項實證——逐元素 marshal、強制自訂 shader、無 per-instance 顏色。
- **逐粒子 `drawBillboard`／`drawCubeV`**：`ccall safe` 逐呼叫開銷 × 粒子數，不可規模化（0001 骨架的權宜做法，本決策淘汰之）。
- **rlgl immediate mode 逐頂點**：同上，FFI 次數 = 頂點數，更差。
