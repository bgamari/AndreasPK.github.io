chcp 65001

REM Temporarily store uncommited changes
git stash

REM # Verify correct branch
git checkout develop

REM # Build new files
cd apkblog

stack exec apkblog clean
stack exec apkblog build

REM # Get previous files
git fetch --all
git checkout -b master --track origin/master

REM # Overwrite existing files with new files
cp -a _site/. ..

REM # Commit
git add -A
git commit -m "Publish."

REM # Push
git push origin master:master

REM # Restoration
git checkout develop
git branch -D master
git stash pop

cd ..