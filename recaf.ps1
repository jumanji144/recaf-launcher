function CheckJava {
    param (
       $Required
    )
    $found = $false;
    $path = "";
    try {
        # Get all the Java installations from the registry save path and version
        $javaInstallations = Get-ItemProperty -Path "HKLM:\SOFTWARE\JavaSoft\Java Runtime Environment" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty "JavaHome", "CurrentVersion" | Where-Object { $_.JavaHome -ne $null -and $_.CurrentVersion -ne $null };
        # Compare the versions to the required version
        $javaInstallations | ForEach-Object {
            $version = $_.CurrentVersion;
            if ($version -ge $Required) {
                $found = $true;
                $path = $_.JavaHome;
            }
        }
    } catch {
        # ignore, try diffrent approach
    }
    # if not found, try `java` command
    if(!$found) {
        $path = Get-Command java -ErrorAction SilentlyContinue;
        try {
            $version = (Get-Command java | Select-Object -ExpandProperty Version).toString();
        } catch {
            # install java 17 via this https://aka.ms/download-jdk/microsoft-jdk-17.0.6-windows-x64.msi
            Invoke-WebRequest -Uri "https://corretto.aws/downloads/latest/amazon-corretto-17-x64-windows-jdk.msi" -OutFile "jdk.msi"
            Start-Process "jdk.msi" -ArgumentList '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /NORESTARTAPPLICATIONS /SUPPRESSMSGBOXES /DIR="C:\Program Files\Amazon Corretto"' -Wait
            Remove-Item "jdk.msi"
            # Set JAVA_HOME
            $env:JAVA_HOME = "C:\Program Files\Amazon Corretto";
            # Add JAVA_HOME to PATH
            $env:PATH = $env:JAVA_HOME + "\bin;" + $env:PATH;
            $version = (Get-Command java | Select-Object -ExpandProperty Version).toString();
            $path = Get-Command java -ErrorAction SilentlyContinue;
        }
        if ($version -lt $Required) {
            Write-Host "Java version $version is not supported. Please install Java $Required or higher."
            exit 1
        }
    }   
    return $path;
}

$RECAF_STORE = $env:LOCALAPPDATA + "\Recaf-Launcher";
$RECAF_VERSION = $args[0];
if ($RECAF_VERSION -eq "" -or $RECAF_VERSION -eq $null) {
    $RECAF_VERSION = "3";
}
$RECAF_LATEST = "$RECAF_STORE\latest$RECAF_VERSION";
# make sure $RECAF_STORE exists
if (!(Test-Path $RECAF_STORE)) {
    New-Item -ItemType Directory -Path $RECAF_STORE | Out-Null
}
# make sure $RECAF_LATEST exists, if not write '0' to it
if (!(Test-Path $RECAF_LATEST)) {
    New-Item -ItemType File -Path $RECAF_LATEST | Out-Null
    Set-Content -Path $RECAF_LATEST -Value "0"
}

$GITHUB_BASE = "https://github.com/Col-E";
$GITHUB_REPO = "Recaf";
$REQUIRED_JAVA = "11";
$GITHUB_API = "https://api.github.com/repos/Col-E";
$GITHUB_PER_PAGE = 100;

function download_recaf {
    param (
        $Tag
    )
    $LATEST_LOCAL = Get-Content $RECAF_LATEST;
    if($Tag -eq "latest") {
        # Load all releases using the GitHub API
        $releases = Invoke-RestMethod -Uri "$GITHUB_API/$GITHUB_REPO/releases";
        $latest = $releases[0];
        if($latest.id -ne $LATEST_LOCAL) {
            # get asset url 
            $asset = $latest.assets[0].browser_download_url;
            # download asset
            $tag_name = $release.tag_name;
            Write-Host "Downloading $tag_name ($asset) ...";
            Invoke-WebRequest -Uri $asset -OutFile $RECAF_STORE\recaf$RECAF_VERSION.jar;
            # write latest id to file
            Set-Content -Path $RECAF_LATEST -Value $latest.id;
        }
    } else {
        if($LATEST_LOCAL -ne $Tag) {
            # go through the pages, compare .[n].tag_name with $1
            # if same, download .[n].assets[0].browser_download_url
            # if not, go to next page, if page does not contain $GITHUB_PER_PAGE entires, stop
            $page = 0;
            while ($true) {
                $releases = (Invoke-RestMethod -Uri "$GITHUB_API/$GITHUB_REPO/releases?per_page=$GITHUB_PER_PAGE&page=$page" -Headers @{"Content-Type" = "application/json"});
                $found = $false;
                foreach ($release in $releases) {
                    if($release.tag_name -eq $Tag) {
                        $asset = $release.assets[0].browser_download_url;
                        $tag_name = $release.tag_name;
                        Write-Host "Downloading $tag_name ($asset) ...";
                        Invoke-WebRequest -Uri $asset -OutFile $RECAF_STORE\recaf$RECAF_VERSION.jar;
                        Set-Content -Path $RECAF_LATEST -Value $release.id;
                        $found = $true;
                        break;
                    }
                }
                if($found) {
                    break;
                }
                if($releases.Count -lt $GITHUB_PER_PAGE) {
                    break;
                }
                $page++;
            }
        }
    }
}

function build_recaf {
    param (
        $Branch,
        $BuildCommand,
        $BuildCommandArgs,
        $BuildFile
    )
    # require 'git'
    if(!(Get-Command git -ErrorAction SilentlyContinue)) {
        Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/v2.39.1.windows.1/Git-2.39.1-64-bit.exe" -OutFile git.exe
        Start-Process "git.exe" -ArgumentList '/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /NORESTARTAPPLICATIONS /SUPPRESSMSGBOXES /DIR="C:\Program Files\Git"' -Wait
        Remove-Item "git.exe"
        Write-Host "Rerun same program, git is now installed";
        exit 0;
    }
    $latest_commit = Invoke-RestMethod -Uri "$GITHUB_API/$GITHUB_REPO/commits/$Branch";
    $latest_commit_id = $latest_commit.sha;
    $latest_local_commit_id = Get-Content $RECAF_LATEST;

    if($latest_commit_id -ne $latest_local_commit_id) {
        # Create tmp directory
        $tmp = $env:TEMP + "\Recaf-Tmp";
        if(Test-Path $tmp) {
            Remove-Item -Path $tmp -Recurse -Force;
        }
        New-Item -ItemType Directory -Path $tmp | Out-Null;
        cd $tmp;
        # Clone the repo
        Invoke-Expression 'git clone $GITHUB_BASE/$GITHUB_REPO';
        cd $GITHUB_REPO;
        # Checkout the branch
        git checkout $Branch;
        # Build Recaf
        Write-Host "Building $RECAF_VERSION";
        Invoke-Expression ".\$BuildCommand $BuildCommandArgs";
        mv $BuildFile $RECAF_STORE\recaf$RECAF_VERSION.jar;
        # Write latest commit id to file
        Set-Content -Path $RECAF_LATEST -Value $latest_commit_id;
        # Cleanup
        cd ..;
        cd ..;
        Remove-Item -Path $tmp -Recurse -Force;
    }

}

function run_recaf {
    $java = CheckJava $REQUIRED_JAVA;
    $arguments = "-jar $RECAF_STORE\recaf$RECAF_VERSION.jar";
    Invoke-Expression "$java $arguments";
}

switch ($RECAF_VERSION) {
    "3" {
        $GITHUB_REPO = "recaf-3x-issues"
        download_recaf "latest";
    }
    "2" {
        $GITHUB_REPO = "Recaf"
        download_recaf "latest";
    }
    "1" {
        $GITHUB_REPO = "Recaf"
        download_recaf "1.15.10";
    }
    "3dev" {
        build_recaf 'dev3' 'gradlew.bat' 'shadowJar' 'recaf-ui/build/libs/recaf*-jar-with-dependencies.jar';
    }
    "2dev" {
        build_recaf 'master' 'mvnw.cmd' "clean package --% -Dmaven.test.skip -Dcheckstyle.skip" 'target/recaf*-jar-with-dependencies.jar';
    }
    Default {
        download_recaf $RECAF_VERSION
    }
}

run_recaf;