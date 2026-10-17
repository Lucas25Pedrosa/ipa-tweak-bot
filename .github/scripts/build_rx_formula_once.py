from pathlib import Path

src = Path('.github/workflows/telegram-inject.yml')
dst = Path('.github/workflows/telegram-inject-rx-formula.yml')

text = src.read_text(encoding='utf-8')

legacy_menu = '''          # TikTok 46.x+: mantém a entrada do RXTikTok no menu
          # mesmo após o refresh remoto das configurações.
          if os.environ.get("BUNDLE_ID") == "com.zhiliaoapp.musically":
              rx_menu_fix = Path(
                  "addons/tiktok/dylib/RXMenuFix-v1.4.dylib"
              )

              if not rx_menu_fix.is_file():
                  raise SystemExit(
                      "❌ RXMenuFix v1.4 ausente no Core: "
                      f"{rx_menu_fix}"
                  )

              rx_menu_fix_str = str(rx_menu_fix)

              if rx_menu_fix_str not in inject_files:
                  inject_files.append(rx_menu_fix_str)
                  print(
                      "✅ RXMenuFix v1.4 adicionado ao TikTok"
                  )

'''

count_menu = text.count(legacy_menu)
if count_menu != 1:
    raise SystemExit(
        f'❌ Bloco RXMenuFix esperado exatamente 1x; encontrado {count_menu}'
    )

text = text.replace(legacy_menu, '', 1)

legacy_root = '''              "com.zhiliaoapp.musically": [
                  "___RXTikTok.dylib",
                  "RXMenuFix-v1.4.dylib",
              ],
'''

count_root = text.count(legacy_root)
if count_root != 1:
    raise SystemExit(
        f'❌ Entrada TikTok ROOT_DYLIBS esperada exatamente 1x; encontrado {count_root}'
    )

text = text.replace(legacy_root, '', 1)

if 'RXMenuFix-v1.4.dylib' in text:
    raise SystemExit('❌ Ainda existe referência global a RXMenuFix-v1.4.dylib')

if '"com.zhiliaoapp.musically": [' in text:
    raise SystemExit('❌ TikTok ainda está preso ao ROOT_DYLIBS legado')

dst.write_text(text, encoding='utf-8')

print('✅ Cópia criada:', dst)
print('✅ RXMenuFix automático removido')
print('✅ TikTok removido do ROOT_DYLIBS')
print('✅ Cyan poderá preservar Frameworks/@rpath conforme o addon selecionado')
