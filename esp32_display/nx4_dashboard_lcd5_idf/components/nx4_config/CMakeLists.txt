# 只有標頭：腳位定義與使用者設定。main 與各驅動元件都要用，
# 所以獨立成元件，避免驅動去相依 main（會形成循環）。
idf_component_register(INCLUDE_DIRS "include")
