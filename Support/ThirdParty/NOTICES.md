# Bundled third-party components

RepoDesk's own license does not replace these components' licenses. Their original
license, legal and notice files are retained in the application bundle.

| Component | Pinned version | License / bundled location | Source |
| --- | --- | --- | --- |
| Eclipse JDT Language Server | 1.61.0, build 202609031315 | EPL-2.0 and licenses of included Eclipse dependencies; `JavaLanguage/jdtls/LICENSE` and plugin notices | [Project source](https://github.com/eclipse-jdtls/eclipse.jdt.ls), [release artifacts](https://download.eclipse.org/jdtls/milestones/1.61.0/) |
| Eclipse Temurin JRE | 21.0.8+9 | GPL-2.0 with the Classpath Exception and component notices; `JavaLanguage/jre/Contents/Home/legal` and `NOTICE` | [Exact upstream source tag](https://github.com/adoptium/jdk21u/tree/jdk-21.0.8%2B9), [binary release](https://github.com/adoptium/temurin21-binaries/releases/tag/jdk-21.0.8%2B9) |
| CFR | 0.152 | MIT; `JarDecompiler/LICENSE.txt` and `NOTICE.md` | [Exact source](https://github.com/leibnitz27/cfr/tree/0.152) |
| JetBrains Mono | See the embedded font metadata | SIL Open Font License 1.1; `MergeFonts/OFL.txt` | [Project source](https://github.com/JetBrains/JetBrainsMono) |

Java runtimes and language-server archives are downloaded unmodified from the
upstream projects and verified with pinned SHA-256 digests by the bootstrap
scripts. Packaging for notarization changes native code signatures only.
Release maintainers must retain these notices and make the corresponding
upstream source and applicable licenses available with every binary release.
Eclipse plugins and the JRE include additional component-specific licenses;
retain the complete runtime directories rather than stripping their legal files.

Upstream licensing references: [Adoptium FAQ](https://adoptium.net/docs/faq) and
[Eclipse JDT LS license](https://github.com/eclipse-jdtls/eclipse.jdt.ls/blob/main/LICENSE).
