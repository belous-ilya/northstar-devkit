; DevKit NSIS installer hooks (registered via bundle.windows.nsis.installerHooks).
;
; Three hooks:
;
; POSTINSTALL removes what the PREVIOUS version installed and this one no
; longer ships. The stock installer only ever adds and overwrites: a script
; that a release deletes stays on disk forever. For DevKit that is not
; cosmetic - the catalog is built from whatever tools\*\_module.psd1
; manifests exist in the install folder, so a category removed from the
; product kept showing up, and kept being runnable, on every install that
; updated instead of installing fresh. The work is done by
; core\Remove-StaleInstallFiles.ps1 (shipped, unit-tested) against
; core\ShippedFiles.txt, not by NSIS code here, for two reasons: it runs
; AFTER the new files are in place, so nothing it does can leave the app
; without its scripts (a delete-first PREINSTALL hook could: the template
; runs it before its own running-app check, which the user may cancel), and
; it depends on nothing inside Tauri's installer template.
;
; PREUNINSTALL closes a running DevKit. The app is admin-only and this
; uninstaller is not elevated, so the template's own "close the running app"
; step cannot touch it: uninstalling while DevKit was running (it is a tray
; app - it nearly always is) showed an error from Windows Settings and, in
; silent mode, did nothing at all without a word. The hook asks for
; administrator rights once and uses them for both things that need them:
; closing DevKit and removing its elevation task.
;
; POSTUNINSTALL cleans up what the app's mandatory-elevation gate
; (src/elevation.rs) created outside the install folder: every launch goes
; through the 'NorthstarDevKit-Admin' scheduled task registered by
; tools/system/Set-DevKitAdminMode.ps1. At POSTUNINSTALL time the install dir
; - and therefore the script itself - is already gone, so the cleanup is
; inlined here instead of calling Set-DevKitAdminMode.ps1 -Off.
;
; The uninstall cleanup of shortcuts and markers is best-effort (a leftover
; shortcut is inert). The task is not: see the macro. One known gap,
; accepted deliberately: if Start-with-Windows had
; been MOVED onto the task's logon trigger, uninstalling removes that
; autostart instead of restoring the Run-key value (the marker that
; remembered it is deleted with the app-data folder by the standard
; uninstaller).

!macro NSIS_HOOK_POSTINSTALL
  ; Windows PowerShell 5.1 is on every supported Windows; the script is
  ; written for it. nsExec runs it without a window. Its output and exit
  ; code are deliberately ignored: leftovers that could not be removed are
  ; not a reason to fail an install that has succeeded.
  ;
  ; By FULL PATH, here and for schtasks below: a bare program name is looked
  ; for in the installer's own folder first, and an update runs this
  ; installer elevated out of a user-writable temp folder - whatever was
  ; planted beside it under that name would run as Administrator.
  ${If} ${FileExists} "$INSTDIR\core\Remove-StaleInstallFiles.ps1"
    nsExec::ExecToStack '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\core\Remove-StaleInstallFiles.ps1" -InstallRoot "$INSTDIR"'
    Pop $0
    Pop $1
    DetailPrint "Removed files from previous versions that are no longer shipped"
  ${EndIf}
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  ; Same rule as POSTUNINSTALL below: every run except /UPDATE.
  ${If} $UpdateMode <> 1
    ; Is DevKit running? Asked through tasklist rather than the template's
    ; process plugin: this needs no admin rights (an elevated process's
    ; image name is visible to everyone) and depends on nothing inside the
    ; template, whose plugin has already changed its arguments once between
    ; Tauri releases. 'find' exits 0 when the name is in the list.
    nsExec::ExecToStack '"$SYSDIR\cmd.exe" /c ""$SYSDIR\tasklist.exe" /FI "IMAGENAME eq ${MAINBINARYNAME}.exe" /NH | "$SYSDIR\find.exe" /I "${MAINBINARYNAME}.exe""'
    Pop $0 ; exit code: 0 means it is running
    Pop $1
    ${If} $0 == 0
      DetailPrint "DevKit is running as administrator; closing it needs administrator rights"
      ; ONE elevated step, so ONE prompt: close DevKit with everything it
      ; started (/T: its sidecar, a running tool, the terminal), and remove
      ; the elevation task while the rights are in hand - POSTUNINSTALL then
      ; finds it gone and does not ask again. Only System32 programs, by full
      ; path. It closes every running DevKit, including a development build:
      ; nothing here can tell them apart without running a script from the
      ; (user-writable) install folder with these rights, which is worse.
      ; Declining the prompt leaves DevKit running; the template's own check
      ; that follows then stops the uninstall, as it always did.
      ExecShellWait "runas" "$SYSDIR\cmd.exe" '/c ""$SYSDIR\taskkill.exe" /IM ${MAINBINARYNAME}.exe /F /T & "$SYSDIR\schtasks.exe" /delete /tn "NorthstarDevKit-Admin" /f"' SW_HIDE
      Sleep 1500
    ${EndIf}
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ; Not when the uninstaller is run with /UPDATE (the template skips its own
  ; shortcut and app-data removal then, for the same reason: the app is
  ; being installed again).
  ;
  ; Every OTHER run cleans up, including the one the installer makes itself
  ; when a newer version is installed by hand with "uninstall before
  ; installing" left selected. That run is indistinguishable, from in here,
  ; from choosing "Uninstall" on the same installer's maintenance page or
  ; from a scripted 'uninstall.exe /S _?=<dir>' - both of which really do
  ; remove DevKit - so it is treated as what it might be. The price is paid
  ; only in that hand-upgrade case: one UAC prompt for schtasks during the
  ; install, and the next launch runs one-time setup again. An elevation
  ; task left behind after a real uninstall is the worse mistake.
  ${If} $UpdateMode <> 1
    ; Remove the elevation scheduled task. It MUST go: it starts whatever
    ; exe sits at the old install path as Administrator, with no prompt, for
    ; anyone who can run 'schtasks /run' as this user - and after an
    ; uninstall that path is an empty slot in a user-writable folder.
    ;
    ; The task was registered by an elevated process, and this uninstaller
    ; is not elevated, so the plain delete below is normally refused. It is
    ; tried first anyway (no prompt when it works), then the task is looked
    ; for again, and only if it is still there is the delete repeated
    ; elevated - the one UAC prompt of an uninstall. Declining it leaves the
    ; task in place; nothing else here depends on it.
    nsExec::ExecToStack '"$SYSDIR\schtasks.exe" /delete /tn "NorthstarDevKit-Admin" /f'
    Pop $0
    Pop $1
    nsExec::ExecToStack '"$SYSDIR\schtasks.exe" /query /tn "NorthstarDevKit-Admin"'
    Pop $0 ; exit code of the query: 0 means the task still exists
    Pop $1
    ${If} $0 == 0
      DetailPrint "Removing the NorthstarDevKit-Admin elevation task needs administrator rights"
      ExecShellWait "runas" "$SYSDIR\schtasks.exe" '/delete /tn "NorthstarDevKit-Admin" /f' SW_HIDE
    ${Else}
      DetailPrint "Removed NorthstarDevKit-Admin elevation task (if present)"
    ${EndIf}

    ; The hidden WSH launcher and the state marker live in the app-data folder.
    Delete "$LOCALAPPDATA\NorthstarDevKit\DevKit-Admin.vbs"
    Delete "$LOCALAPPDATA\NorthstarDevKit\admin-mode.json"

    ; The 'DevKit (Admin)' shortcuts the setup script wrote next to the stock
    ; NSIS shortcuts ($SMPROGRAMS matches [Environment]::GetFolderPath('Programs')).
    Delete "$DESKTOP\DevKit (Admin).lnk"
    Delete "$SMPROGRAMS\DevKit (Admin).lnk"
  ${EndIf}
!macroend
