# Unity 最小範例（func-spec 0011 S5）

把這個資料夾當**參考材料**，不是可執行專案：Unity 專案不進 repo，所以這裡只有兩個要貼進去的 `.cs`，加上一份「照做就會動」的步驟。定位與 [`examples/c/main.c`](../c/main.c) 相同——**手動 smoke**，不進 CI。

驗證的是 [`include/particle_magic.h`](../../include/particle_magic.h) 這一份合約；Unity 端沒有任何特權，能載入共享庫的環境（Godot C#、純 .NET）照抄即可。

---

## 1. 需要的檔案

| 來源 | 放到 Unity 專案的 |
|---|---|
| `bindings/csharp/ParticleMagic.cs` | `Assets/Scripts/ParticleMagic.cs` |
| `examples/unity/SpellRenderer.cs` | `Assets/Scripts/SpellRenderer.cs` |
| `examples/unity/PmSmoke.cs`（選用，見 §7） | `Assets/Editor/PmSmoke.cs` |
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

## 7. Smoke：一行指令

`PmSmoke.cs`（本資料夾）是這個範例的自動檢查，放進 `Assets/Editor/` 後用 [Unity CLI](https://docs.unity3d.com/) 跑：

```bash
unity run <你的專案> --non-interactive -- \
    -executeMethod PmSmoke.Run -pmSpellDir <repo>/assets/spells
```

全過回傳 0，報告同時寫在 `<專案>/Logs/pm-smoke-result.txt` 與 editor log。批次模式、`-nographics`，不需要場景也不需要螢幕。

它涵蓋 `cabal test` **測不到**的那一段——Unity 自己的 P/Invoke marshaller、DLL 從 `Assets/Plugins` 載入、以及 `SpellRenderer` 的 Mesh 路徑：

| 檢查 | 為什麼是這裡才驗得到 |
|---|---|
| `pm_abi_version` / `pm_max_particles` | 綁定常數與 DLL 實際回傳一致 |
| 六欄取樣後全部有限、`life ∈ [0,1]`、alpha 非零 | marshaller 真的搬了 float 與 `0xRRGGBBAA`（順序錯會在這裡露餡） |
| `pm_project` 兩個平面逐位元等於 `(x,y,−z)` / `(x,z,−y)` | 跨 marshaller 之後仍然是**選軸**，沒有被轉成別的浮點 |
| `pm_depth_order` 是置換且由遠而近 | 同上 |
| 壞 plane／負長度 → `PM_ERR_ARGS` 且零寫出 | 錯誤路徑不會弄髒宿主陣列 |
| `pm_free` 後再 `pm_cast` 仍可用 | 沒有人偷偷 `pm_shutdown` |
| Mesh 頂點數 = 粒子數 × 4、全部有限、bounds 的 z 已翻轉 | 手性翻轉真的發生在頂點上 |
| alpha 批次的 quad 順序**等於 `pm_depth_order` 回的置換** | 排序不是元件自己另外排的 |

一個實測到的資料觀察：目前 9 個範例陣裡，alpha 批次的 buffer 順序**本來就**是由遠而近（發射器沿法線擠出，index 與深度單調相關），所以「排序前後看起來一樣」是正常的，不代表排序沒生效——上表最後一列驗的是置換本身相等，不受這件事影響。

## 8. 一次好幾張陣：場景模式（func-spec 0018）

上面整份說的都是**一張陣**：一個 `PmSpell*`、一個 `SpellRenderer`。要同時有好幾張（火球還在燒、護盾又升起來），不必自己開一個 `List<IntPtr>` 記帳——0018 把 `Magic.Scene` 整個送上了 C ABI，`ParticleMagic.cs` 裡的 `pm_scene_*` 十個函數就是它。

差別只有三點，但每一點做錯都是靜默的：

| | 單張陣 | 場景 |
|---|---|---|
| handle | `pm_cast` → `PmSpell*`，`pm_free` 釋放 | `pm_scene_new(globalCap)` → `PmScene*`，`pm_scene_free` 釋放 |
| 新增／移除 | 一個 handle 一個法術 | `pm_scene_cast` 回一個 `int` id;提前收掉用 `pm_scene_dismiss(id)` |
| 六欄開多大 | `pm_max_particles()`（**單一法術**的上限） | **你自己傳給 `pm_scene_new` 的 `globalCap`** |

第三列是最容易出錯的一條：`pm_max_particles()` 界定的是一張陣，場景可以同時裝好幾張。拿它去配置場景的緩衝，第二張陣一進來 `pm_scene_observe` 就開始回 `Pm.ErrCapacity`,而且照 all-or-nothing 的慣例**整幀不畫**——看起來像閃爍，不像錯誤。

每幀的迴圈與單張陣同形,只是換一組函數:

```csharp
scene = Pm.pm_scene_new(globalCap);          // 一次
...
Pm.pm_scene_advance(scene, fixedDt);         // 固定時步，一幀可能多次
int batches = Pm.pm_scene_observe(scene, px, py, pz, size, life, color,
                                  globalCap, batchInfo, maxBatches);
// batchInfo 的佈局、PM_BATCH_INFO_STRIDE、手性、深度排序全部與 pm_observe 相同
```

新增的錯誤碼 `Pm.ErrQuota`（`PM_ERR_QUOTA`, −5）是唯一值得**反應**而不只是記 log 的一個：法術本身編得起來,只是場景滿了,所以宿主可以 `pm_scene_dismiss` 掉一個舊的再施一次。`pm_scene_budget(scene, out used, out cap)` 告訴你還剩多少;被拒的那一次**完全沒有改動場景**,三個查詢都與拒收前相同。

另外兩條規則:

- **法術不能跨模式。** 進了場景的法術**沒有** `PmSpell*`,既不能丟給 `pm_free`,也不能把既有的 `PmSpell*` 搬進場景。每次施法二選一。
- **一個 scene 一個執行緒**,與 `PmSpell*` 同一條紀律(ADR-0011 D4)。

本輪**沒有**附一個 `SceneRenderer.cs`——要看可跑的完整軌跡(兩張共存 → 第三張被配額拒 → 一張自然結束後配額釋放 → 第三張成功),跑 C 範例即可,它與 Unity 走的是同一份 DLL:

```
cabal build flib:particle-magic-ffi
clang -Iinclude examples/c/scene.c particle-magic-ffi.dll -o pm_scene.exe
./pm_scene.exe assets/spells/ring-fire.json
```

（`batch_info` 不會告訴你某個 batch 屬於哪一張陣——Haskell 面自己也不知道,C 面不多知道一件事。真有這個需求時的做法寫在 func-spec 0018 §8。）

## 9. 還是要用眼睛看的三件事

自動 smoke 驗不到的，按 Play 自己確認：

- [ ] 粒子的動態與顏色漸變看起來對（美術判斷，沒有斷言可寫）
- [ ] **停止播放 → 再按 Play → 仍正常**（Editor 不卸載 native plugin，這是 §4 那個坑真正會發作的地方；批次模式每次都是新 process，驗不到）
- [ ] Profiler 中每幀 GC Alloc 不隨粒子數成長（緩衝有重複使用）
