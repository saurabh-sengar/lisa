# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

### HELPERS ###
function New-ConstantsFile {
    param(
        $LogDir,
        $CurrentTestData
    )

    Write-LogInfo "Generating constants.sh ..."
    $constantsFile = "$LogDir\constants.sh"
    Set-Content -Value "# Generated by LISAv2 Automation." -Path $constantsFile
    foreach ($param in $currentTestData.TestParameters.param) {
        Add-Content -Value "$param" -Path $constantsFile | Out-Null
        Write-LogInfo "$param added to constants.sh"
    }
    Write-LogInfo "constants.sh created successfully..."
}

function Get-LinuxPerfRunCode {
        $runPerfCode = @"
chmod +x perf_fio.sh
./perf_fio.sh &> fioConsoleLogs.txt
. utils.sh
collect_VM_properties
"@
        $parsePerfResultsCode = @"
chmod +x *.sh
cp fio_jason_parser.sh gawk JSON.awk utils.sh /root/FIOLog/jsonLog/
cd /root/FIOLog/jsonLog/
./fio_jason_parser.sh
cp perf_fio.csv /root
chmod 666 /root/perf_fio.csv
"@
    return @{
        "run_perf" = $runPerfCode;
        "parse_perf_results" = $parsePerfResultsCode;
    }
}

function Run-DemultiplexFioPerfResult {
    param(
        $InputPerfResultFile,
        $OutMaxIOPSforModePerfResultFile = "$LogDir\maxIOPSforMode.csv",
        $OutMaxIOPSforBlockSizePerfResultFile = "$LogDir\maxIOPSforBlockSize.csv",
        $OutPerfResultFile = "$LogDir\fioData.csv"
    )

    foreach ($line in (Get-Content $InputPerfResultFile)) {
        if ($line -imatch "Max IOPS of each mode" ) {
            $maxIOPSforMode = $true
            $maxIOPSforBlockSize = $false
            $fioData = $false
        }
        if ($line -imatch "Max IOPS of each BlockSize") {
            $maxIOPSforMode = $false
            $maxIOPSforBlockSize = $true
            $fioData = $false
        }
        if ($line -imatch "Iteration,TestType,BlockSize") {
            $maxIOPSforMode = $false
            $maxIOPSforBlockSize = $false
            $fioData = $true
        }
        if ($maxIOPSforMode) {
            Add-Content -Value $line -Path $OutMaxIOPSforModePerfResultFile
        }
        if ($maxIOPSforBlockSize) {
            Add-Content -Value $line -Path $OutMaxIOPSforBlockSizePerfResultFile
        }
        if ($fioData) {
            Add-Content -Value $line -Path $OutPerfResultFile
        }
    }
}

function Get-FioPerformanceResults {
    param(
        $FioPerfDataCsvFile
    )

    $fioPerfResults = @()
    $fioPerfResultObject = @{
        "meta_data" = @{
            "mode" = $null;
            "q_depth" = $null;
         };
        "io_per_second" = $null;
        "latency_usecond" = $null;
        "block_size" = $null;
    }

    $fioDataCsv = Import-Csv -Path $FioPerfDataCsvFile
    $fioDataCsv | ForEach-Object {
        $fioTestResultEntry = $_
        $currentTestResultObject = $fioPerfResultObject.Clone()
        $currentTestResultObject["meta_data"] = $fioPerfResultObject["meta_data"].Clone()

        $qDepth = $fioTestResultEntry.Threads
        $testType = $fioTestResultEntry.TestType
        $currentTestResultObject["meta_data"]["mode"] = $testType
        $currentTestResultObject["meta_data"]["q_depth"] = $qDepth
        $ioPerSecondKey = $testType.replace("rand", "") + "IOPS"
        $currentTestResultObject["io_per_second"] = $fioTestResultEntry.$ioPerSecondKey
        $latencyUsecondKey = "MaxOf" + $testType.replace("rand", "") + "MeanLatency"
        $currentTestResultObject["latency_usecond"] = $fioTestResultEntry.$latencyUsecondKey
        $currentTestResultObject["block_size"] = $fioTestResultEntry.BlockSize.Replace("K","")

        $fioPerfResults += $currentTestResultObject
    }
    return $fioPerfResults
}

function Consume-FioPerformanceResults {
    param(
        $FioPerformanceResults,
        $DBConfig
    )

    $dataSource = $DBConfig.server
    $DBuser = $DBConfig.user
    $DBpassword = $DBConfig.password
    $database = $DBConfig.dbname
    $dataTableName = $DBConfig.dbtable
    $TestCaseName = $DBConfig.testTag

    if ($dataSource -And $DBuser -And $DBpassword -And $database -And $dataTableName) {
        $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
        $HostOS = cat "$LogDir\VM_properties.csv" | Select-String "Host Version"| %{$_ -replace ",Host Version,",""}
        $GuestOSType = "Linux"
        $GuestDistro = cat "$LogDir\VM_properties.csv" | Select-String "OS type"| %{$_ -replace ",OS type,",""}
        $GuestSize = $allVMData.InstanceSize
        $KernelVersion  = cat "$LogDir\VM_properties.csv" | Select-String "Kernel version"| %{$_ -replace ",Kernel version,",""}

        $SQLQuery = "INSERT INTO $dataTableName (TestCaseName,TestDate,HostType,HostBy,HostOS,GuestOSType,GuestDistro,GuestSize,KernelVersion,DiskSetup,BlockSize_KB,qDepth,seq_read_iops,seq_read_lat_usec,rand_read_iops,rand_read_lat_usec,seq_write_iops,seq_write_lat_usec,rand_write_iops,rand_write_lat_usec) VALUES "

        foreach ($fioPerfResult in $FioPerformanceResults) {
            $seq_read_iops = 0
            $seq_read_lat_usec = 0
            $rand_read_iops = 0
            $rand_read_lat_usec = 0
            $seq_write_iops = 0
            $seq_write_lat_usec = 0
            $rand_write_iops = 0
            $rand_write_lat_usec = 0

            if ($fioPerfResult["meta_data"]["mode"] -eq "read") {
                $seq_read_iops = $fioPerfResult["io_per_second"]
                $seq_read_lat_usec = $fioPerfResult["latency_usecond"]
            }

            if ($fioPerfResult["meta_data"]["mode"] -eq "randread") {
                $rand_read_iops = $fioPerfResult["io_per_second"]
                $rand_read_lat_usec = $fioPerfResult["latency_usecond"]
            }

            if ($fioPerfResult["meta_data"]["mode"] -eq "write") {
                $seq_write_iops = $fioPerfResult["io_per_second"]
                $seq_write_lat_usec = $fioPerfResult["latency_usecond"]
            }

            if ($fioPerfResult["meta_data"]["mode"] -eq "randwrite") {
                $rand_write_iops = $fioPerfResult["io_per_second"]
                $rand_write_lat_usec = $fioPerfResult["latency_usecond"]
            }

            $BlockSize_KB = $fioPerfResult["block_size"]
            $qDepth = $fioPerfResult["meta_data"]["q_depth"]
            $SQLQuery += "('$TestCaseName','$(Get-Date -Format yyyy-MM-dd)','$TestPlatform','$TestLocation','$HostOS','$GuestOSType','$GuestDistro','$GuestSize','$KernelVersion','RAID0:12xP30','$BlockSize_KB','$QDepth','$seq_read_iops','$seq_read_lat_usec','$rand_read_iops','$rand_read_lat_usec','$seq_write_iops','$seq_write_lat_usec','$rand_write_iops','$rand_write_lat_usec'),"
            Write-LogInfo "Collected performace data for $qDepth qDepth."
        }
        Write-LogInfo "Uploading the test results to database.."

        $SQLQuery = $SQLQuery.TrimEnd(',')
        Upload-TestResultToDatabase $SQLQuery
    } else {
        Write-LogInfo "Invalid database details."
    }
}

#### MAIN ####
function Main {
    param(
        $AllVMData,
        $LogDir,
        $CurrentTestData
    )

    try {
        Provision-VMsForLisa -allVMData $allVMData -installPackagesOnRoleNames "none"
        New-ConstantsFile -LogDir $LogDir -CurrentTestData $CurrentTestData

        Write-LogInfo "Starting test..."
        $linuxPerfCode = Get-LinuxPerfRunCode
        Set-Content "$LogDir\StartFioTest.sh" $linuxPerfCode["run_perf"]
        Set-Content "$LogDir\ParseFioTestLogs.sh" $linuxPerfCode["parse_perf_results"]
        Copy-RemoteFiles -uploadTo $allVMData.PublicIP -port $allVMData.SSHPort `
            -files "$constantsFile,$LogDir\StartFioTest.sh,$LogDir\ParseFioTestLogs.sh" `
            -username "root" -password $password -upload
        Copy-RemoteFiles -uploadTo $allVMData.PublicIP -port $allVMData.SSHPort `
            -files $currentTestData.files -username "root" -password $password -upload
        $null = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort `
            -username "root" -password $password -command "chmod +x *.sh" -runAsSudo
        $testJob = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort `
            -username "root" -password $password -command "bash StartFioTest.sh" `
            -RunInBackground -runAsSudo

        Write-LogInfo "Monitoring test run..."
        while ((Get-Job -Id $testJob).State -eq "Running") {
            $currentStatus = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort `
                -username "root" -password $password -command "tail -1 fioConsoleLogs.txt" `
                -runAsSudo
            Write-LogInfo "Current Test Status: $currentStatus"
            Wait-Time -seconds 20
        }

        Write-LogInfo "Checking test run status..."
        $finalStatus = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort `
            -username "root" -password $password -command "cat state.txt"
        Copy-RemoteFiles -downloadFrom $allVMData.PublicIP -port $allVMData.SSHPort `
            -username "root" -password $password -download -downloadTo $LogDir -files "FIOTest-*.tar.gz"
        Copy-RemoteFiles -downloadFrom $allVMData.PublicIP -port $allVMData.SSHPort `
            -username "root" -password $password -download -downloadTo $LogDir -files "VM_properties.csv"
        if ($finalStatus -imatch "TestFailed") {
            Write-LogErr "Test failed. Last known status : $currentStatus."
            $testResult = "FAIL"
        } elseif ($finalStatus -imatch "TestAborted") {
            Write-LogErr "Test Aborted. Last known status : $currentStatus."
            $testResult = "ABORTED"
        } elseif ($finalStatus -imatch "TestCompleted") {
            $null = Run-LinuxCmd -ip $allVMData.PublicIP -port $allVMData.SSHPort `
                -username "root" -password $password -command "/root/ParseFioTestLogs.sh"
            Copy-RemoteFiles -downloadFrom $allVMData.PublicIP -port $allVMData.SSHPort `
                -username "root" -password $password -download -downloadTo $LogDir `
                -files "perf_fio.csv"
            $testResult = "PASS"
        } elseif ($finalStatus -imatch "TestRunning") {
            Write-LogInfo "Powershell job for test is completed but test is still running."
            $testResult = "FAILED"
        }
        Write-LogInfo "Test result: $testResult"

        Write-LogInfo "Parsing and consuming test results..."
        $outPerfResultFile = "$LogDir\fioData.csv"
        Run-DemultiplexFioPerfResult -InputPerfResultFile "$LogDir\perf_fio.csv" `
            -OutPerfResultFile $outPerfResultFile

        $fioPerfResults = Get-FioPerformanceResults $outPerfResultFile

        $fioPerfResultsFile = "${LogDir}\$($currentTestData.testName)_perf_results.json"
        $fioPerfResults | ConvertTo-Json | Out-File $fioPerfResultsFile -Encoding "ascii"
        Write-LogInfo "Perf results in json format saved at: ${fioPerfResultsFile}"

        Consume-FioPerformanceResults -FioPerformanceResults $fioPerfResults `
            -DBConfig $xmlConfig.config.$TestPlatform.database

        Write-LogInfo "Test Completed"
    } catch {
        $ErrorMessage =  $_.Exception.Message
        $ErrorLine = $_.InvocationInfo.ScriptLineNumber
        Write-LogErr "EXCEPTION: $ErrorMessage at line: $ErrorLine"
    } finally {
        if (!$testResult) {
            $testResult = "Aborted"
        }
    }

    return $testResult
}

Main -AllVMData $allVMData `
    -LogDir $LogDir -CurrentTestData $currentTestData
