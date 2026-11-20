# 0170. Quick Look file preview

Area: workspace

## Split the file name by hand for the temporary file

`QuickLookTemporaryFile.write` takes the last `/`-separated component of the name itself instead of using `URL(fileURLWithPath:)`. That initializer resolves dot names such as `.` and `..` against the working directory instead of leaving them to the `File` fallback name.

Lives in: `HermesMobile/Features/Shared/QuickLookFilePreview.swift`
