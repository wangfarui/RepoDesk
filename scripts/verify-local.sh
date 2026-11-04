#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
module_cache="${project_dir}/build/ModuleCache"

# Swift macro plugins otherwise try to nest sandbox-exec inside constrained agent sessions.
swiftc() {
  command swiftc -disable-sandbox "$@"
}

mkdir -p "${module_cache}"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Features/BranchNameHoverHint.swift" \
  "${project_dir}/scripts/verify-branch-name-hover.swift" \
  -o "${project_dir}/build/verify-branch-name-hover"

"${project_dir}/build/verify-branch-name-hover"

swiftc \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -typecheck \
  "${project_dir}"/RepoDeskApp/**/*.swift

swiftc -parse "${project_dir}"/RepoDeskTests/**/*.swift

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Features/FileSystemPathCopy.swift" \
  "${project_dir}/scripts/verify-file-system-path-copy.swift" \
  -o "${project_dir}/build/verify-file-system-path-copy"

"${project_dir}/build/verify-file-system-path-copy"

swiftc \
  -parse-as-library \
  -emit-library \
  -emit-module \
  -enable-testing \
  -module-name RepoDesk \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}"/RepoDeskApp/**/*.swift \
  -emit-module-path "${project_dir}/build/RepoDesk.swiftmodule" \
  -o "${project_dir}/build/libRepoDesk.dylib"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" -L "${project_dir}/build" -lRepoDesk \
  "${project_dir}/scripts/verify-idea-merge-interaction.swift" \
  -o "${project_dir}/build/verify-idea-merge-interaction"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-idea-merge-interaction" --verify

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-three-way-merge.swift" \
  -o "${project_dir}/build/verify-three-way-merge"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-three-way-merge"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-import-folding.swift" \
  -o "${project_dir}/build/verify-java-import-folding"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-java-import-folding"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-file-tree-horizontal-scrolling.swift" \
  -o "${project_dir}/build/verify-file-tree-horizontal-scrolling"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-file-tree-horizontal-scrolling"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-semantic-highlighting.swift" \
  -o "${project_dir}/build/verify-java-semantic-highlighting"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-java-semantic-highlighting"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-xml-syntax-highlighting.swift" \
  -o "${project_dir}/build/verify-xml-syntax-highlighting"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-xml-syntax-highlighting"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-semantic-switching.swift" \
  -o "${project_dir}/build/verify-java-semantic-switching"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-java-semantic-switching"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-file-navigation-history.swift" \
  -o "${project_dir}/build/verify-file-navigation-history"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-file-navigation-history"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-mybatis-navigation.swift" \
  -o "${project_dir}/build/verify-mybatis-navigation"

DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-mybatis-navigation"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-navigation-popup-layout.swift" \
  -o "${project_dir}/build/verify-java-navigation-popup-layout"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-java-navigation-popup-layout"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-commit-execution.swift" \
  -o "${project_dir}/build/verify-commit-execution"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-commit-execution"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-merge-conflict-resolution.swift" \
  -o "${project_dir}/build/verify-merge-conflict-resolution"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-merge-conflict-resolution"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-commit-execution-rendering.swift" \
  -o "${project_dir}/build/verify-commit-execution-rendering"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-commit-execution-rendering"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-git-remote-operation-rendering.swift" \
  -o "${project_dir}/build/verify-git-remote-operation-rendering"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-git-remote-operation-rendering"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-merge-conflict-rendering.swift" \
  -o "${project_dir}/build/verify-merge-conflict-rendering"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-merge-conflict-rendering"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-git-push-preparation.swift" \
  -o "${project_dir}/build/verify-git-push-preparation"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-git-push-preparation"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-git-branch-pull.swift" \
  -o "${project_dir}/build/verify-git-branch-pull"

DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-git-branch-pull"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-git-push-diff-loading.swift" \
  -o "${project_dir}/build/verify-git-push-diff-loading"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-git-push-diff-loading"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-git-push-diff-ui-performance.swift" \
  -o "${project_dir}/build/verify-git-push-diff-ui-performance"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-git-push-diff-ui-performance"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-settings.swift" \
  -o "${project_dir}/build/verify-settings"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-settings"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-language.swift" \
  -o "${project_dir}/build/verify-java-language"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-java-language"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-cross-repository-field-navigation.swift" \
  -o "${project_dir}/build/verify-java-cross-repository-field-navigation"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-java-cross-repository-field-navigation"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-contextual-method-callers.swift" \
  -o "${project_dir}/build/verify-java-contextual-method-callers"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-java-contextual-method-callers"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-java-navigation-first-click.swift" \
  -o "${project_dir}/build/verify-java-navigation-first-click"

DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-java-navigation-first-click"

"${script_dir}/bootstrap-java-language-runtime.sh"
"${script_dir}/bootstrap-jar-decompiler.sh"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-history-jar.swift" \
  -o "${project_dir}/build/verify-history-jar"

DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-history-jar"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-history-jar-rendering.swift" \
  -o "${project_dir}/build/verify-history-jar-rendering"

DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-history-jar-rendering"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-jdt-language-server.swift" \
  -o "${project_dir}/build/verify-jdt-language-server"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
REPODESK_JAVA_LANGUAGE_RUNTIME="${project_dir}/build/JavaLanguageRuntime" \
  "${project_dir}/build/verify-jdt-language-server"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-interaction-restoration.swift" \
  -o "${project_dir}/build/verify-interaction-restoration"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-interaction-restoration"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-interaction-rendering.swift" \
  -o "${project_dir}/build/verify-interaction-rendering"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-interaction-rendering"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-interaction-responsiveness.swift" \
  -o "${project_dir}/build/verify-interaction-responsiveness"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-interaction-responsiveness"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-file-tabs-repository-layout.swift" \
  -o "${project_dir}/build/verify-file-tabs-repository-layout"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-file-tabs-repository-layout" --legacy-scrollers
DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-file-tabs-repository-layout" --overlay-scrollers

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-performance-suite.swift" \
  -o "${project_dir}/build/verify-performance-suite"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-performance-suite"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-qa-integration.swift" \
  -o "${project_dir}/build/verify-qa-integration"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-qa-integration"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-settings-rendering.swift" \
  -o "${project_dir}/build/verify-settings-rendering"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-settings-rendering"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-changes-repository-rendering.swift" \
  -o "${project_dir}/build/verify-changes-repository-rendering"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-changes-repository-rendering"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/ChangesOutline.swift" \
  "${project_dir}/RepoDeskApp/Settings/ChangesAutoExpansionSettings.swift" \
  "${project_dir}/scripts/verify-changes-outline.swift" \
  -o "${project_dir}/build/verify-changes-outline"

"${project_dir}/build/verify-changes-outline"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffLayoutMetrics.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameColorScale.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameAnnotationCell.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffView.swift" \
  "${project_dir}/scripts/verify-git-diff-layout.swift" \
  -o "${project_dir}/build/verify-git-diff-layout"

"${project_dir}/build/verify-git-diff-layout"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffLayoutMetrics.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameColorScale.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameAnnotationCell.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffView.swift" \
  "${project_dir}/scripts/verify-git-diff-selection.swift" \
  -o "${project_dir}/build/verify-git-diff-selection"

"${project_dir}/build/verify-git-diff-selection"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffLayoutMetrics.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameColorScale.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameAnnotationCell.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffView.swift" \
  "${project_dir}/scripts/verify-git-diff-mouse-copy.swift" \
  -o "${project_dir}/build/verify-git-diff-mouse-copy"

"${project_dir}/build/verify-git-diff-mouse-copy"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffLayoutMetrics.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameColorScale.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameAnnotationCell.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffView.swift" \
  "${project_dir}/RepoDeskApp/Features/GitMergeDiffView.swift" \
  "${project_dir}/scripts/verify-git-merge-diff.swift" \
  -o "${project_dir}/build/verify-git-merge-diff"

"${project_dir}/build/verify-git-merge-diff"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Git/GitDiffParser.swift" \
  "${project_dir}/scripts/verify-git-diff-crlf.swift" \
  -o "${project_dir}/build/verify-git-diff-crlf"

"${project_dir}/build/verify-git-diff-crlf"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffLayoutMetrics.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameColorScale.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameAnnotationCell.swift" \
  "${project_dir}/RepoDeskApp/Features/GitDiffView.swift" \
  "${project_dir}/scripts/verify-git-diff-performance.swift" \
  -o "${project_dir}/build/verify-git-diff-performance"

"${project_dir}/build/verify-git-diff-performance"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Features/GitDiffComparisonWindow.swift" \
  "${project_dir}/scripts/verify-git-diff-window.swift" \
  -o "${project_dir}/build/verify-git-diff-window"

"${project_dir}/build/verify-git-diff-window"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Files/MarkdownPreviewParser.swift" \
  "${project_dir}/scripts/verify-markdown-preview.swift" \
  -o "${project_dir}/build/verify-markdown-preview"

"${project_dir}/build/verify-markdown-preview"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-markdown-preview-selection.swift" \
  -o "${project_dir}/build/verify-markdown-preview-selection"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-markdown-preview-selection"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/scripts/verify-content-search.swift" \
  -o "${project_dir}/build/verify-content-search"

"${project_dir}/build/verify-content-search"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Domain/RegisteredRepository.swift" \
  "${project_dir}/RepoDeskApp/JavaLanguage/JavaLanguageModels.swift" \
  "${project_dir}/RepoDeskApp/JavaLanguage/JavaSyntaxHighlighter.swift" \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/RepoDeskApp/Features/SourceLineNavigation.swift" \
  "${project_dir}/RepoDeskApp/Files/XMLSyntaxHighlighter.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameColorScale.swift" \
  "${project_dir}/RepoDeskApp/Features/NativeCodeEditor.swift" \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/JavaImportFolding.swift" \
  "${project_dir}/RepoDeskApp/Settings/ShortcutSettings.swift" \
  "${project_dir}/RepoDeskApp/Features/StreamingOutputView.swift" \
  "${project_dir}/scripts/verify-output-follow.swift" \
  -o "${project_dir}/build/verify-output-follow"

"${project_dir}/build/verify-output-follow"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Domain/RegisteredRepository.swift" \
  "${project_dir}/RepoDeskApp/JavaLanguage/JavaLanguageModels.swift" \
  "${project_dir}/RepoDeskApp/JavaLanguage/JavaSyntaxHighlighter.swift" \
  "${project_dir}/RepoDeskApp/Features/ContentFind.swift" \
  "${project_dir}/RepoDeskApp/Features/SourceLineNavigation.swift" \
  "${project_dir}/RepoDeskApp/Files/XMLSyntaxHighlighter.swift" \
  "${project_dir}/RepoDeskApp/Features/GitBlameColorScale.swift" \
  "${project_dir}/RepoDeskApp/Features/NativeCodeEditor.swift" \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Features/JavaImportFolding.swift" \
  "${project_dir}/RepoDeskApp/Settings/ShortcutSettings.swift" \
  "${project_dir}/scripts/verify-source-editor-scroll-performance.swift" \
  -o "${project_dir}/build/verify-source-editor-scroll-performance"

"${project_dir}/build/verify-source-editor-scroll-performance" < /dev/null

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-history-refresh-stability.swift" \
  -o "${project_dir}/build/verify-history-refresh-stability"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-history-refresh-stability"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-history-merge-diff.swift" \
  -o "${project_dir}/build/verify-history-merge-diff"

repodesk_library_path="${project_dir}/build"
DYLD_LIBRARY_PATH="${repodesk_library_path}" \
  "${project_dir}/build/verify-history-merge-diff"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Files/WorkspaceChangeMonitor.swift" \
  "${project_dir}/scripts/verify-file-monitor.swift" \
  -framework CoreServices \
  -o "${project_dir}/build/verify-file-monitor"

"${project_dir}/build/verify-file-monitor"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Files/WorkspaceChangeMonitor.swift" \
  "${project_dir}/scripts/verify-workspace-change-stress.swift" \
  -framework CoreServices \
  -o "${project_dir}/build/verify-workspace-change-stress"

"${project_dir}/build/verify-workspace-change-stress"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Diagnostics/AppDiagnosticLogger.swift" \
  "${project_dir}/scripts/verify-diagnostics.swift" \
  -o "${project_dir}/build/verify-diagnostics"

"${project_dir}/build/verify-diagnostics"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Process/CommandRunner.swift" \
  "${project_dir}/scripts/verify-command-runner.swift" \
  -o "${project_dir}/build/verify-command-runner"

"${project_dir}/build/verify-command-runner"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Tasks/TaskModels.swift" \
  "${project_dir}/RepoDeskApp/Tasks/SystemTaskRunner.swift" \
  "${project_dir}/scripts/verify-task-runner.swift" \
  -o "${project_dir}/build/verify-task-runner"

"${project_dir}/build/verify-task-runner"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Git/GitBlameParser.swift" \
  "${project_dir}/scripts/verify-git-blame.swift" \
  -o "${project_dir}/build/verify-git-blame"

"${project_dir}/build/verify-git-blame"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-git-blame-colors.swift" \
  -o "${project_dir}/build/verify-git-blame-colors"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-git-blame-colors"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Process/CommandRunner.swift" \
  "${project_dir}/RepoDeskApp/Diagnostics/AppDiagnosticLogger.swift" \
  "${project_dir}/RepoDeskApp/Git/GitModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitThreeWayMergeDocument.swift" \
  "${project_dir}/RepoDeskApp/Git/GitMergeTextResolver.swift" \
  "${project_dir}/RepoDeskApp/Git/GitPushModels.swift" \
  "${project_dir}/RepoDeskApp/Git/GitBlameParser.swift" \
  "${project_dir}/RepoDeskApp/Git/GitDiffParser.swift" \
  "${project_dir}/RepoDeskApp/Git/GitHistoryParser.swift" \
  "${project_dir}/RepoDeskApp/Git/GitStatusParser.swift" \
  "${project_dir}/RepoDeskApp/Git/GitRepositoryReader.swift" \
  "${project_dir}/RepoDeskApp/Git/GitLineChanges.swift" \
  "${project_dir}/RepoDeskApp/Files/FileModels.swift" \
  "${project_dir}/RepoDeskApp/Files/DocumentLoader.swift" \
  "${project_dir}/scripts/verify-git-review.swift" \
  -o "${project_dir}/build/verify-git-review"

"${project_dir}/build/verify-git-review"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  "${project_dir}/RepoDeskApp/Maven/MavenRunHistory.swift" \
  "${project_dir}/RepoDeskApp/Maven/MavenModels.swift" \
  "${project_dir}/RepoDeskApp/Maven/MavenRunHistoryStore.swift" \
  "${project_dir}/RepoDeskApp/Maven/MavenHomeValidator.swift" \
  "${project_dir}/RepoDeskApp/Maven/JavaHomeValidator.swift" \
  "${project_dir}/RepoDeskApp/Maven/MavenPathValidator.swift" \
  "${project_dir}/RepoDeskApp/Files/WorkspaceChangeMonitor.swift" \
  "${project_dir}/RepoDeskApp/Maven/MavenProjectRefreshPlanner.swift" \
  "${project_dir}/RepoDeskApp/Process/CommandRunner.swift" \
  "${project_dir}/RepoDeskApp/Maven/MavenCommandBuilder.swift" \
  "${project_dir}/RepoDeskApp/Maven/MavenProjectScanner.swift" \
  "${project_dir}/scripts/verify-maven.swift" \
  -framework CoreServices \
  -o "${project_dir}/build/verify-maven"

"${project_dir}/build/verify-maven"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-maven-queue.swift" \
  -o "${project_dir}/build/verify-maven-queue"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-maven-queue"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-search-result-selection.swift" \
  -o "${project_dir}/build/verify-search-result-selection"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-search-result-selection"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-history-hash-search.swift" \
  -o "${project_dir}/build/verify-history-hash-search"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-history-hash-search"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-history-presentation.swift" \
  -o "${project_dir}/build/verify-history-presentation"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-history-presentation"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-git-line-changes.swift" \
  -o "${project_dir}/build/verify-git-line-changes"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-git-line-changes"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-files-editing-performance.swift" \
  -o "${project_dir}/build/verify-files-editing-performance"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-files-editing-performance"

swiftc \
  -parse-as-library \
  -Xcc "-fmodules-cache-path=${module_cache}" \
  -strict-concurrency=complete \
  -warnings-as-errors \
  -I "${project_dir}/build" \
  -L "${project_dir}/build" \
  -lRepoDesk \
  "${project_dir}/scripts/verify-editor-input.swift" \
  -o "${project_dir}/build/verify-editor-input"

DYLD_LIBRARY_PATH="${project_dir}/build" \
  "${project_dir}/build/verify-editor-input"

"${script_dir}/build-local.sh"

app_bundle="${project_dir}/build/RepoDesk.app"
app_info="${app_bundle}/Contents/Info.plist"
app_icon="${app_bundle}/Contents/Resources/RepoDesk.icns"

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app_info}")" == "0.1.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app_info}")" == "2" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "${app_info}")" == "RepoDesk.icns" ]]
[[ -s "${app_icon}" ]]
codesign --verify --deep --strict "${app_bundle}"

echo "Local verification passed (including QA integration replacement checks)"
