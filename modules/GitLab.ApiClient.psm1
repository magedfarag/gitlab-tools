Set-StrictMode -Version Latest

class GitLabRequestMetrics {
    [string]$Endpoint
    [int]$StatusCode
    [int]$Retries
    [double]$DurationMs
    [int]$Items
    [datetime]$Timestamp
}

class GitLabApiError : System.Exception {
    [int]$StatusCode
    [string]$Endpoint
    GitLabApiError([string]$message, [int]$statusCode, [string]$endpoint, [System.Exception]$inner) : base($message, $inner) {
        $this.StatusCode = $statusCode
        $this.Endpoint = $endpoint
    }
}

function New-GitLabApiClient {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$BaseUri,
        [Parameter(Mandatory)][string]$AccessToken,
        [int]$DefaultPerPage = 100,
        [int]$MaxPages = 100,
        [int]$MaxRetries = 3,
        [int]$InitialDelayMs = 250,
        [int]$MaxDelayMs = 16000,
        [int]$MinDelayBetweenCallsMs = 200,
        [switch]$EnableMetrics
    )

    $tracker = [ordered]@{
        LastCallStart    = Get-Date
        CallsInLastBlock = 0
        WindowStart      = Get-Date
        DelayMs          = $MinDelayBetweenCallsMs
    }

    $client = [pscustomobject]@{
        BaseUri        = $BaseUri
        AccessToken    = $AccessToken
        DefaultPerPage = $DefaultPerPage
        MaxPages       = $MaxPages
        MaxRetries     = $MaxRetries
        InitialDelayMs = $InitialDelayMs
        MaxDelayMs     = $MaxDelayMs
        MinDelayMs     = $MinDelayBetweenCallsMs
        EnableMetrics  = $EnableMetrics.IsPresent
        Tracker        = $tracker
        Metrics        = New-Object System.Collections.ArrayList
    }

    $client | Add-Member -MemberType ScriptMethod -Name InvokeEndpoint -Value {
        param(
            [string]$Endpoint,
            [ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method = 'GET',
            [hashtable]$Headers,
            [object]$Body,
            [switch]$AllPages,
            [int]$PerPage,
            [int]$MaxPages,
            [hashtable]$Query
        )

        $client = $this
        $tracker = $client.Tracker

        $mergedHeaders = @{
            'PRIVATE-TOKEN' = $client.AccessToken
            'Content-Type'  = 'application/json'
        }
        if ($Headers) {
            foreach ($key in $Headers.Keys) {
                $mergedHeaders[$key] = $Headers[$key]
            }
        }

        $perPage = if ($PerPage) { $PerPage } else { $client.DefaultPerPage }
        $maxPages = if ($MaxPages) { $MaxPages } else { $client.MaxPages }

        $results = @()
        $page = 1
        $retry = 0

        do {
            $continuePaging = $AllPages.IsPresent
            $itemsThisPage = 0
            $startTime = Get-Date

            if ($tracker.LastCallStart) {
                $elapsedSinceLast = (Get-Date) - $tracker.LastCallStart
                if ($elapsedSinceLast.TotalMilliseconds -lt $client.MinDelayMs) {
                    $sleepMs = [math]::Max($client.MinDelayMs - $elapsedSinceLast.TotalMilliseconds, $tracker.DelayMs)
                    Start-Sleep -Milliseconds ([int]$sleepMs)
                }
            }
            $tracker.LastCallStart = Get-Date

            try {
                $endpointParts = $Endpoint.Split('?', 2)
                $pathPart = $endpointParts[0]
                $existingQuery = if ($endpointParts.Count -gt 1) { $endpointParts[1] } else { '' }

                $queryParams = @{}
                if ($existingQuery) {
                    foreach ($pair in $existingQuery.Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
                        $segments = $pair.Split('=', 2)
                        if ($segments.Count -gt 0) {
                            $key = $segments[0]
                            $value = if ($segments.Count -gt 1) { [uri]::UnescapeDataString($segments[1]) } else { '' }
                            $queryParams[$key] = $value
                        }
                    }
                }

               if ($Query) {
                    foreach ($key in $Query.Keys) {
                        $queryParams[$key] = $Query[$key]
                    }
                }

                if ($AllPages) {
                    $queryParams['page'] = $page
                    $queryParams['per_page'] = $perPage
                } elseif ($PerPage) {
                    $queryParams['per_page'] = $perPage
                }

                $queryParts = @()
                foreach ($key in $queryParams.Keys) {
                    $value = $queryParams[$key]
                    $queryParts += "$key=$([uri]::EscapeDataString([string]$value))"
                }
                $queryString = if ($queryParts.Count -gt 0) { '?' + ($queryParts -join '&') } else { '' }

                $uri = [uri]::new($client.BaseUri, "/api/v4/$pathPart$queryString")
                $requestParams = @{
                    Uri         = $uri
                    Method      = $Method
                    Headers     = $mergedHeaders
                    TimeoutSec  = 120
                    ErrorAction = 'Stop'
                }

                if ($Body) {
                    if ($Body -is [string]) {
                        $requestParams.Body = $Body
                    } else {
                        $requestParams.Body = ($Body | ConvertTo-Json -Depth 10)
                    }
                }

                $response = Invoke-RestMethod @requestParams
                $itemsThisPage = if ($response -is [System.Array]) { $response.Length } elseif ($null -eq $response) { 0 } else { 1 }
                $results += $response

                if ($client.EnableMetrics) {
                    $raw = Invoke-WebRequest @requestParams
                    $duration = (Get-Date) - $startTime
                    $metric = [GitLabRequestMetrics]::new()
                    $metric.Endpoint = $Endpoint
                    $metric.StatusCode = [int]$raw.StatusCode
                    $metric.Retries = $retry
                    $metric.DurationMs = $duration.TotalMilliseconds
                    $metric.Items = $itemsThisPage
                    $metric.Timestamp = Get-Date
                    [void]$client.Metrics.Add($metric)
                }

                if (-not $continuePaging) { break }

                if ($itemsThisPage -lt $perPage -or $page -ge $maxPages) {
                    $continuePaging = $false
                } else {
                    $page++
                }
                $retry = 0
            }
            catch {
                $statusCode = 0
                if ($_.Exception -and $_.Exception.Response) {
                    $statusCode = $_.Exception.Response.StatusCode.value__
                    $retry++
                    if ($statusCode -eq 429) {
                        $retry = [math]::Min($retry, $client.MaxRetries)
                        $delay = [math]::Min($client.MaxDelayMs, $client.InitialDelayMs * [math]::Pow(2, $retry - 1))
                        Start-Sleep -Milliseconds $delay
                        continue
                    } elseif ($statusCode -ge 500 -and $retry -le $client.MaxRetries) {
                        $delay = [math]::Min($client.MaxDelayMs, $client.InitialDelayMs * [math]::Pow(2, $retry - 1))
                        Start-Sleep -Milliseconds $delay
                        continue
                    }
                }

                throw [GitLabApiError]::new("GitLab API call failed for $Endpoint", $statusCode, $Endpoint, $_.Exception)
            }
        } while ($continuePaging)

        return $results
    }

    return $client
}

function Invoke-GitLabApiRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Client,
        [Parameter(Mandatory)][string]$Endpoint,
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method = 'GET',
        [switch]$AllPages,
        [int]$PerPage,
        [int]$MaxPages,
        [object]$Body,
        [hashtable]$Query,
        [hashtable]$Headers
    )

    return $Client.InvokeEndpoint(
        $Endpoint,
        $Method,
        $Headers,
        $Body,
        $AllPages,
        $PerPage,
        $MaxPages,
        $Query
    )
}

Export-ModuleMember -Function New-GitLabApiClient,Invoke-GitLabApiRequest
