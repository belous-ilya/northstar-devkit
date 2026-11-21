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
; The uninstall cleanup of shortcuts and markers is best-effort (a leftover
; shortcut is inert). The task is not: see the macro. One known gap,
; accepted deliberately: if Start-with-Windows had
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
    nsExec::ExecToStack 'schtasks /delete /tn "NorthstarDevKit-Admin" /f'
    Pop $0
    Pop $1
    nsExec::ExecToStack 'schtasks /query /tn "NorthstarDevKit-Admin"'
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
