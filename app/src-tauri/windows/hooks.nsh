; DevKit NSIS installer hooks (registered via bundle.windows.nsis.installerHooks).
;
; Two hooks:
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
; POSTUNINSTALL cleans up what the app's mandatory-elevation gate
; (src/elevation.rs) created outside the install folder: every launch goes
; through the 'NorthstarDevKit-Admin' scheduled task registered by
; tools/system/Set-DevKitAdminMode.ps1. At POSTUNINSTALL time the install dir
; - and therefore the script itself - is already gone, so the cleanup is
; inlined here instead of calling Set-DevKitAdminMode.ps1 -Off.
;
; The uninstall cleanup is best-effort: a leftover shortcut is inert, and a
; leftover task points at a deleted exe (the gate re-runs setup on
; reinstall). One known gap, accepted deliberately: if Start-with-Windows had
; been MOVED onto the task's logon trigger, uninstalling removes that
; autostart instead of restoring the Run-key value (the marker that
; remembered it is deleted with the app-data folder by the standard
; uninstaller).

!macro NSIS_HOOK_POSTINSTALL
  ; powershell.exe (Windows PowerShell 5.1) is on every supported Windows;
  ; the script is written for it. nsExec runs it without a window. Its
  ; output and exit code are deliberately ignored: leftovers that could not
  ; be removed are not a reason to fail an install that has succeeded.
  ${If} ${FileExists} "$INSTDIR\core\Remove-StaleInstallFiles.ps1"
    nsExec::ExecToStack 'powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\core\Remove-StaleInstallFiles.ps1" -InstallRoot "$INSTDIR"'
    Pop $0
    Pop $1
    DetailPrint "Removed files from previous versions that are no longer shipped"
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTUNINSTALL
  ; Not when the uninstaller is run as a step of an update (/UPDATE): the
  ; app is about to be installed again, and deleting the elevation task
  ; would send the next launch back through one-time setup and its UAC
  ; prompt. The template skips its own shortcut and app-data removal in
  ; that mode for the same reason.
  ${If} $UpdateMode <> 1
    ; Remove the elevation scheduled task. 'schtasks /delete' from the
    ; user's filtered token succeeds for tasks in their own task library; if
    ; it does not, the task is left behind (see header).
    nsExec::ExecToStack 'schtasks /delete /tn "NorthstarDevKit-Admin" /f'
    Pop $0
    Pop $0
    DetailPrint "Removed NorthstarDevKit-Admin elevation task (if present)"

    ; The hidden WSH launcher and the state marker live in the app-data folder.
    Delete "$LOCALAPPDATA\NorthstarDevKit\DevKit-Admin.vbs"
    Delete "$LOCALAPPDATA\NorthstarDevKit\admin-mode.json"

    ; The 'DevKit (Admin)' shortcuts the setup script wrote next to the stock
    ; NSIS shortcuts ($SMPROGRAMS matches [Environment]::GetFolderPath('Programs')).
    Delete "$DESKTOP\DevKit (Admin).lnk"
    Delete "$SMPROGRAMS\DevKit (Admin).lnk"
  ${EndIf}
!macroend
