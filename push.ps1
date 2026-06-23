cd D:\Project\Scope\ZZ\STO\trunk\v1x\program\arm\RemotePlay-iOS
git push origin main 2>&1 | Tee-Object -FilePath push_output.txt
"EXIT_CODE: $LASTEXITCODE" | Add-Content push_output.txt
"REMOTE_AFTER_PUSH:" | Add-Content push_output.txt
git rev-parse origin/main | Add-Content push_output.txt
"LOCAL_AFTER_PUSH:" | Add-Content push_output.txt
git rev-parse main | Add-Content push_output.txt
