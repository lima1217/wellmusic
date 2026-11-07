# WellMusic glossary

One word per thing, one verb per action, in both languages. `src/strings.zig` follows this table; `strings.zig`'s tests reject middle dots.

Sources, in priority order: **Apple Music's own strings** (extracted from `/System/Applications/Music.app/Contents/Resources/{en,zh_CN}.lproj`, see [apple-terms.csv](apple-terms.csv)), then the Apple Style Guide, then what mainland Chinese music apps (QQ 音乐 / 网易云音乐) show users. Where Apple's Chinese reads as translated, the local convention wins, and the reason is written down.

| concept | English | 中文 | why |
|---|---|---|---|
| a piece of music | song | 歌曲 / 首 | Apple: Song → 歌曲, "%S songs" → "%S首歌曲". Never "track" on screen. |
| add files | Add Songs… | 添加歌曲… | One verb, **Add**, for every way in (the old copy mixed Add / Import / 导入). Ellipsis: a dialog follows (Apple HIG). |
| add a folder | Add Album from Folder… | 从文件夹添加专辑… | Says what you pick (a folder) and what you get (an album). |
| take out of the library | Remove from Library | 从资料库移除 | Apple uses exactly this pair. Not "Delete": the user's original files are untouched. |
| the play queue | Queue | 播放列表 | Apple's 待播清单 is unfamiliar; 网易云 / QQ 音乐 call this list 播放列表. In English, "Playlist" means a saved list, so the queue is "Queue". |
| insert after current | Play Next | 下一首播放 | Apple zh is 插播 (a broadcast term); 下一首播放 is the local app wording. |
| performer | Artist | 歌手 | Apple uses 艺人; 歌手 is what Chinese music apps show and what users say. |
| many performers | Various Artists | 群星 | Apple: 群星. |
| loose songs | Singles | 单曲 | The album that holds files added one by one. |
| random order | Shuffle On / Off | 随机播放已开启 / 已关闭 | Tooltip states the current state. |
| repeat modes | Repeat Off / All / One | 不循环 / 列表循环 / 单曲循环 | Local music-app idiom; Apple's 重复播放一首 reads as translated. |
| empty the queue | Clear | 清空 | Apple 清除; 清空 is the local word for emptying a list. |
| artwork | cover | 封面 | Apple 插图; every local app says 封面. |
| reverse a removal | Undo (Cmd+Z) | 撤销 | Apple. |
| appearance | Dark Mode / Light Mode | 深色模式 / 浅色模式 | macOS System Settings wording. |

**Tone.** Never urge ("Now", "立即"). Notices state what happened, then why: "Added 3 songs: 1 already in your library". Errors say what to do next in plain words, without "path" or "file system".
