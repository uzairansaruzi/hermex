import SwiftUI
import UIKit

/// The glyph that stands for a file wherever its name is shown: the file tree and file
/// chips. Each case is an image in the `FileIcons` asset folder (Pierre's file-tree
/// icons plus T3 Code's additions, see README). Resolution order is an exact filename
/// (`package.json`, `Dockerfile`), then `tsconfig.*.json`, then the longest matching
/// extension chain (`env.local` before `local`), then the plain document glyph.
enum FileIcon: String, CaseIterable {
    case agents, astro, babel, bash, biome, bootstrap, browserslist, bun, c, claude, cpp, css
    case database, docker, eslint, font, git, go, graphql, html, image, javascript, json
    case markdown, mcp, nextjs, npm, oxc, package, pnpm, postcss, prettier, python, react
    case readme, ruby, rust, sass, stylelint, svelte, svg, svgo, swift, table, tailwind
    case terraform, text, tsconfig, typescript, vite, vscode, vue, wasm, webpack, yml, zig, zip
    case `default`

    var assetName: String { "FileIcons/\(rawValue)" }
    var image: Image { Image(assetName) }
    var uiImage: UIImage? { UIImage(named: assetName) }

    /// Resolves the icon for a filename or path. A trailing `:line[:column]` is ignored so
    /// a chat reference like `main.swift:12` resolves like `main.swift`.
    static func resolve(_ nameOrPath: String) -> FileIcon {
        var basename = nameOrPath.split(separator: "/").last.map(String.init) ?? nameOrPath
        if let match = basename.firstMatch(of: /:\d+(?::\d+)?$/) {
            basename = String(basename[..<match.range.lowerBound])
        }
        basename = basename.lowercased()

        if let icon = iconByName[basename] {
            return icon
        }
        if basename.hasPrefix("tsconfig."), basename.hasSuffix(".json") {
            return .tsconfig
        }
        let segments = basename.split(separator: ".", omittingEmptySubsequences: false)
        for index in 1..<max(segments.count, 1) {
            if let icon = iconByExtension[segments[index...].joined(separator: ".")] {
                return icon
            }
        }
        return .default
    }

    // MARK: - Tables

    /// Exact lowercased filenames.
    private static let iconByName: [String: FileIcon] = [
        ".babelrc": .babel, ".babelrc.json": .babel,
        ".bash_profile": .bash, ".bashrc": .bash, ".zprofile": .bash, ".zshenv": .bash, ".zshrc": .bash,
        ".browserslistrc": .browserslist,
        ".dockerignore": .docker, "dockerfile": .docker, "compose.yaml": .docker, "compose.yml": .docker,
        "docker-compose.yaml": .docker, "docker-compose.yml": .docker, "docker-compose.override.yml": .docker,
        ".eslintignore": .eslint, ".eslintrc": .eslint, ".eslintrc.cjs": .eslint, ".eslintrc.js": .eslint,
        ".eslintrc.json": .eslint, ".eslintrc.yaml": .eslint, ".eslintrc.yml": .eslint,
        "eslint.config.js": .eslint, "eslint.config.cjs": .eslint, "eslint.config.mjs": .eslint,
        "eslint.config.mts": .eslint, "eslint.config.ts": .eslint,
        ".gitattributes": .git, ".gitignore": .git, ".gitkeep": .git, ".gitmodules": .git,
        ".oxlintrc.json": .oxc,
        ".postcssrc": .postcss, ".postcssrc.json": .postcss, ".postcssrc.yaml": .postcss, ".postcssrc.yml": .postcss,
        "postcss.config.js": .postcss, "postcss.config.cjs": .postcss, "postcss.config.mjs": .postcss,
        "postcss.config.ts": .postcss,
        ".prettierignore": .prettier, ".prettierrc": .prettier, ".prettierrc.json": .prettier,
        ".prettierrc.cjs": .prettier, ".prettierrc.js": .prettier, ".prettierrc.mjs": .prettier,
        ".prettierrc.toml": .prettier, ".prettierrc.yaml": .prettier, ".prettierrc.yml": .prettier,
        "prettier.config.js": .prettier, "prettier.config.cjs": .prettier, "prettier.config.mjs": .prettier,
        ".stylelintignore": .stylelint, ".stylelintrc": .stylelint, ".stylelintrc.cjs": .stylelint,
        ".stylelintrc.js": .stylelint, ".stylelintrc.json": .stylelint, ".stylelintrc.mjs": .stylelint,
        ".stylelintrc.yaml": .stylelint, ".stylelintrc.yml": .stylelint,
        "stylelint.config.js": .stylelint, "stylelint.config.cjs": .stylelint, "stylelint.config.mjs": .stylelint,
        ".terraform.lock.hcl": .terraform,
        "agents.md": .agents,
        "babel.config.js": .babel, "babel.config.cjs": .babel, "babel.config.json": .babel, "babel.config.mjs": .babel,
        "biome.json": .biome, "biome.jsonc": .biome,
        "bun.lock": .bun, "bun.lockb": .bun, "bunfig.toml": .bun,
        "claude.md": .claude,
        "gemfile": .ruby, "rakefile": .ruby,
        "next.config.js": .nextjs, "next.config.mjs": .nextjs, "next.config.mts": .nextjs, "next.config.ts": .nextjs,
        "package.json": .package,
        "pnpm-lock.yaml": .pnpm, "pnpm-workspace.yaml": .pnpm,
        "readme.md": .readme,
        "svgo.config.js": .svgo, "svgo.config.cjs": .svgo, "svgo.config.mjs": .svgo, "svgo.config.ts": .svgo,
        "tailwind.config.js": .tailwind, "tailwind.config.cjs": .tailwind, "tailwind.config.mjs": .tailwind,
        "tailwind.config.ts": .tailwind,
        "tsconfig.json": .tsconfig,
        "vite.config.js": .vite, "vite.config.mjs": .vite, "vite.config.mts": .vite, "vite.config.ts": .vite,
        "webpack.config.js": .webpack, "webpack.config.babel.js": .webpack, "webpack.config.cjs": .webpack,
        "webpack.config.mjs": .webpack, "webpack.config.ts": .webpack,
    ]

    /// Lowercased extension chains, longest match first (`env.local` before `local`).
    private static let iconByExtension: [String: FileIcon] = [
        "7z": .zip, "bz2": .zip, "gz": .zip, "jar": .zip, "rar": .zip, "tar": .zip, "tgz": .zip, "zip": .zip,
        "astro": .astro,
        "avif": .image, "bmp": .image, "gif": .image, "icns": .image, "ico": .image, "jpeg": .image,
        "jpg": .image, "png": .image, "webp": .image,
        "code-workspace": .vscode,
        "bash": .bash, "fish": .bash, "sh": .bash, "zsh": .bash,
        "c": .c, "h": .c,
        "cc": .cpp, "cpp": .cpp, "cxx": .cpp, "hh": .cpp, "hpp": .cpp, "hxx": .cpp, "inl": .cpp,
        "css": .css, "less": .css, "postcss": .css,
        "csv": .table, "tsv": .table,
        "cts": .typescript, "mts": .typescript, "ts": .typescript,
        "db": .database, "sql": .database, "sqlite": .database, "sqlite3": .database,
        "env": .text, "env.development": .text, "env.local": .text, "env.production": .text, "ini": .text, "txt": .text,
        "eot": .font, "woff": .font, "woff2": .font,
        "erb": .ruby, "rake": .ruby, "rb": .ruby,
        "go": .go,
        "gql": .graphql, "graphql": .graphql,
        "htm": .html, "html": .html,
        "js": .javascript, "mjs": .javascript,
        "json": .json, "jsonc": .json,
        "jsx": .react, "tsx": .react,
        "md": .markdown, "mdx": .markdown, "mdx.tsx": .markdown,
        "py": .python, "pyi": .python, "pyw": .python, "pyx": .python,
        "rs": .rust,
        "sass": .sass, "scss": .sass,
        "svelte": .svelte,
        "svg": .svg,
        "swift": .swift,
        "tf": .terraform, "tfstate": .terraform, "tfvars": .terraform,
        "vue": .vue,
        "wasm": .wasm,
        "yaml": .yml, "yml": .yml,
        "zig": .zig,
    ]
}
