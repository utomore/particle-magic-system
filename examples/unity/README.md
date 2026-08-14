# Unity 最小範例（func-spec 0011 S5）

把這個資料夾當**參考材料**，不是可執行專案：Unity 專案不進 repo，所以這裡只有兩個要貼進去的 `.cs`，加上一份「照做就會動」的步驟。定位與 [`examples/c/main.c`](../c/main.c) 相同——**手動 smoke**，不進 CI。

驗證的是 [`include/particle_magic.h`](../../include/particle_magic.h) 這一份合約；Unity 端沒有任何特權，能載入共享庫的環境（Godot C#、純 .NET）照抄即可。

---

## 1. 需要的檔案

| 來源 | 放到 Unity 專案的 |
|---|---|
| `bindings/csharp/ParticleMagic.cs` | `Assets/Scripts/ParticleMagic.cs` |
| `examples/unity/SpellRenderer.cs` | `Assets/Scripts/SpellRenderer.cs` |
| 建置產物 `particle-magic-ffi.dll` | `Assets/Plugins/x86_64/particle-magic-ffi.dll` |
| 任一張魔法陣 JSON（`assets/spells/*.json`） | `Assets/Resources/ring-fire.json`（副檔名改 `.txt` 或用 `TextAsset` 匯入） |

建 DLL：

```
cabal build flib:particle-magic-ffi
```

產物在 `dist-newstyle/build/<平台>/ghc-<版本>/particle-magic-0.1.0.0/f/particle-magic-ffi/build/particle-magic-ffi/`。Windows 是 `.dll`、Linux 是 `.so`、macOS 是 `.dylib`；`Pm.Dll` 只寫 `"particle-magic-ffi"`，前後綴由 runtime 自己補。

在 Inspector 選中 DLL，勾 **Standalone** 與 **Editor**、平台設 **x86_64**。Editor 沒勾的話按 Play 會找不到函數。

## 2. 場景設定

1. 空物件 → 掛上 `SpellRenderer`。
2. `Circle Json` 指到匯入的 JSON `TextAsset`。
3. 兩個材質（Unlit + Vertex Color 即可）：
   - `Alpha Material`：`Blend SrcAlpha OneMinusSrcAlpha`、`ZWrite Off`
   - `Additive Material`：`Blend SrcAlpha One`、`ZWrite Off`
4. 相機看向物件；`ring-fire` 的粒子在原點附近數個單位內。

## 3. 預期畫面

- 按 Play 後**立刻**有粒子（施法 casting 階段），沿環狀陣形展開、向上發散。
- 顏色沿生命週期漸變，末端 alpha 歸零（不是硬切）。
- 法術結束後粒子歸零、Console 無錯誤；`pm_free` 由 `Update` 自動呼叫。
- **再按一次 Play 仍然正常**——這是這個範例最重要的一項（見 §4）。

## 4. 唯一真正的坑：不要呼叫 `pm_shutdown()`

GHC 的 RTS **停掉之後無法在同一個 process 重啟**，而 Unity Editor 停止播放時**不卸載 native plugin**——下一次按 Play 還是同一個 process。所以：

- `pm_init()` 由 `[RuntimeInitializeOnLoadMethod]` 呼叫一次，之後讓它活著；
- `OnDestroy` / `OnApplicationQuit` **不呼叫** `pm_shutdown()`；
- 真正要做的清理只有 `pm_free()`，每個 handle 一次。

症狀對照：第一次 Play 正常、第二次直接掛掉 → 有人呼叫了 `pm_shutdown()`。

## 5. 另外三件會靜默出錯的事

| 事 | 做法 | 做錯的症狀 |
|---|---|---|
| **手性** | 右手系（+Z 朝觀者）↔ Unity 左手系：進出各翻一次 Z（`PmConvert.ToPm` / `-pz[i]`） | 不會崩潰；`vortex` 力場旋轉方向反過來 |
| **固定時步** | accumulator，一幀可能 `pm_advance` 好幾次，`pm_observe` 只一次 | 幀率影響模擬結果，重播不一致 |
| **緩衝大小** | `Pm.pm_max_particles()`，不要用 `PM_MAX_PARTICLES` 常數 | 核心上限提升後 `pm_observe` 回 `PM_ERR_CAPACITY`，整幀不畫 |

`PM_MAX_PARTICLES` 永遠是第 1 代的 4096（header 凍結）；`pm_max_particles()` 才是跟著核心走的查詢。

## 6. 深度排序

範例對 **alpha 批次**呼叫 `pm_depth_order(PM_PLANE_SIDE_XY, …)` 取得由遠而近的索引置換，加法批次則維持原序（加法可交換、不需排序）。這是 0011 把投影送上 C ABI 的用途：宿主不必自己重寫一份排序，也就不會和 Haskell 端排出不同的結果。

3D 相機的深度排序仍是宿主的事（`pm_depth_order` 給的是正交平面深度）；若你的相機不是側視，改用自己的視距排序即可——庫不阻止。

## 7. 手動 smoke 檢查表

依序確認，全過即算 S5 通過：

- [ ] Console 無 ABI mismatch（`pm_abi_version()` == 1）
- [ ] 粒子出現、動、顏色漸變、結束後歸零
- [ ] 停止播放 → 再按 Play → 仍正常（沒有 `pm_shutdown`）
- [ ] 把 `Sort Alpha Batches` 關掉再開，alpha 批次的前後遮蔽關係有可見差異
- [ ] Profiler 中每幀 GC Alloc 不隨粒子數成長（緩衝有重複使用）
