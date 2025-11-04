# Global Configuration
:local enableLogging false

# External DNS config
:local DnsServer "DNS SERVER HERE - For example; 192.168.1.2:5380"
:local ApiToken "PUT YOUR TOKEN HERE"          

# Internal DNS config
:local DHCPtag "#*# DHCP2DNS"
:local LogPrefix "DHCP2DNS"

# Utility: Trim string (removes leading/trailing spaces and null characters)
:local trimString do={
    :local outStr ""
    :for i from=0 to=([:len $inStr] - 1) do={
        :local tmp [:pick $inStr $i]
        :if (($tmp != " ") and ($tmp != "\00")) do={
            :set outStr ($outStr . $tmp)
        }
    }
    :return $outStr
}

# Utility: Convert IP to hostname (e.g., 192.168.1.10 -> 192-168-1-10)
:local ip2Host do={
    :local outStr ""
    :for i from=0 to=([:len $inStr] - 1) do={
        :local tmp [:pick $inStr $i]
        :if ($tmp = ".") do={ :set tmp "-" }
        :set outStr ($outStr . $tmp)
    }
    :return $outStr
}

# Utility: Clean string by filtering out all invalid DNS characters.
:local safeFilterHostname do={
    # Valid chars: a-z, A-Z, 0-9, and the hyphen (-). Spaces and other symbols are filtered out.
    :local validChars "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    :local outStr ""
    :local char ""
    :local i 0 ; # Explicit declaration for loop counter stability
    
    :for i from=0 to=([:len $inStr] - 1) do={
        :set char [:pick $inStr $i (1 + $i)] ; # Pick one character: from $i to $i + 1
        
        # If the character is found in the valid set (position >= 0), keep it.
        :if ([:find $validChars $char] >= 0) do={
            :set outStr ($outStr . $char)
        }
    }
    :return $outStr
}

:local newEntriesAdded 0 ; # Counter for new entries added

:log info "$LogPrefix: Script started."

# Step 1: Build active lease map
/ip dhcp-server lease
:local activeFQDNs ""
:foreach leaseId in=[find where status="bound"] do={
    :local leaseIP [get $leaseId address]
    :local leaseHost ""

    :local rawComment [get $leaseId comment]
    :local rawHostName [get $leaseId host-name]
    :if ($enableLogging) do={
        :log info "$LogPrefix: --- Processing Lease $leaseIP ---"
        :log debug "$LogPrefix: $leaseIP | Raw Comment: '$rawComment' | Raw Hostname: '$rawHostName'"
    }

    # 1. Try Comment Field (Highest Priority)
    :local tempName [$trimString inStr=$rawComment]
    :if ([:len $tempName] > 0) do={
        :set leaseHost $tempName
        :if ($enableLogging) do={
            :log info "$LogPrefix: $leaseIP | SELECTED: Comment (Uncleaned: '$leaseHost')"
        }
    }

    # 2. Try Host-Name Field
    :if ([:len $leaseHost] = 0) do={
        :local tempName [$trimString inStr=$rawHostName]
        
        :if ([:len $tempName] > 0) do={
            :set leaseHost $tempName
            :if ($enableLogging) do={
                :log info "$LogPrefix: $leaseIP | SELECTED: Host-Name (Uncleaned: '$leaseHost')"
            }
        }
    }

    /ip dhcp-server network
    :local domain [get [find $leaseIP in address] domain]
    :set domain [$trimString inStr=$domain]

    # FINAL CLEANING: Using the universally compatible safe filter
    :if ([:len $leaseHost] > 0) do={
        :local finalHostName [$safeFilterHostname inStr=$leaseHost]
        
        :if ([:len $finalHostName] > 0) do={
            :set leaseHost $finalHostName
            :set leaseHost [:convert $leaseHost transform=lc to=raw]
            :if ($enableLogging) do={
                :log info "$LogPrefix: $leaseIP | CLEANED: '$leaseHost'"
            }
        } else={
             # The final cleaning step failed (e.g., input was only garbage symbols), revert to IP to ensure DNS is valid.
             :set leaseHost [$ip2Host inStr=$leaseIP]
             :if ($enableLogging) do={
                :log info "$LogPrefix: $leaseIP | FALLBACK: Post-Clean Failed (Reverting to IP)"
            }
        }
    }


    # 3. Fallback to IP Address (Only used if the FINAL CLEANING also failed)
    :if ([:len $leaseHost] = 0) do={
        :set leaseHost [$ip2Host inStr=$leaseIP]
        :if ($enableLogging) do={
            :log info "$LogPrefix: $leaseIP | SELECTED: IP Fallback ('$leaseHost')"
        }
    }


    :if ([:len $domain] > 0) do={
        :local fqdn ($leaseHost . "." . $domain)
        :set activeFQDNs ($activeFQDNs . "," . $fqdn)
        :if ($enableLogging) do={
            :log debug "$LogPrefix: $leaseIP | Final FQDN added: $fqdn"
        }
    }
}

# Step 2: Remove stale DNS entries
/ip dns static
:foreach id in=[find where comment~$DHCPtag] do={
    :local fqdn [get $id name]
    :local address [get $id address]
    :local domain [:pick $fqdn ([:find $fqdn "."] + 1) 9999]

    :if ([:find $activeFQDNs ("," . $fqdn)] = nil) do={
        remove $id
        :if ($enableLogging) do={
            :log info "$LogPrefix: Removed stale DNS '$fqdn' -> '$address'"
        }

        :if ([:len $DnsServer] != 0) do={
            :local delUrl ("http://" . $DnsServer . "/api/zones/records/delete?domain=" . $fqdn . "&zone=" . $domain . "&type=A&overwrite=true&IPAddress=" . $address . "&token=" . $ApiToken)
            /tool fetch url=$delUrl dst-path=release.tmp
        }
    }
}

# Step 3: Rebuild DNS entries from current leases
/ip dhcp-server lease
:foreach leaseId in=[find where status="bound"] do={
    :local leaseIP [get $leaseId address]
    :local leaseServer [get $leaseId server]
    :local leaseHost ""

    # 1. Try Comment Field (Highest Priority)
    :local tempName [get $leaseId comment]
    :set tempName [$trimString inStr=$tempName]
    :if ([:len $tempName] > 0) do={
        :set leaseHost $tempName
    }

    # 2. Try Host-Name Field
    :if ([:len $leaseHost] = 0) do={
        :local tempName [get $leaseId host-name]
        :set tempName [$trimString inStr=$tempName]
        
        :if ([:len $tempName] > 0) do={
            :set leaseHost $tempName
        }
    }

    # TTL Calculation (Unchanged)
    /ip dhcp-server
    :local ttlRaw [get [find name=$leaseServer] lease-time]
    :local hrs; :set hrs [:tonum [:pick $ttlRaw 0 2]]
    :local min; :set min [:tonum [:pick $ttlRaw 3 5]]
    :local sec; :set sec [:tonum [:pick $ttlRaw 6 8]]
    :local ttlH; :set ttlH ($hrs * 3600)
    :local ttlM; :set ttlM ($min * 60)
    :local ttlS; :set ttlS $sec
    :local ttl; :set ttl ($ttlH + $ttlM + $ttlS)

    /ip dhcp-server network
    :local domain [get [find $leaseIP in address] domain]
    :set domain [$trimString inStr=$domain]

    # FINAL CLEANING (Applied before fallback check)
    :if ([:len $leaseHost] > 0) do={
        :local finalHostName [$safeFilterHostname inStr=$leaseHost]
        :if ([:len $finalHostName] > 0) do={
            :set leaseHost $finalHostName
        } else={
             # The final cleaning step failed, revert leaseHost to empty to force IP fallback
             :set leaseHost ""
        }
    }

    # 3. Fallback to IP Address
    :if ([:len $leaseHost] = 0) do={
        :set leaseHost [$ip2Host inStr=$leaseIP]
    }

    # Standard practice: convert the final hostname to lowercase using the stable command
    :set leaseHost [:convert $leaseHost transform=lc to=raw]

    :if ([:len $domain] = 0) do={ :next }

    /ip dns static
    :local fqdn ($leaseHost . "." . $domain)
    :local existingId [find name=$fqdn]
    :local needsUpdate true

    :if ([:len $existingId] > 0) do={
        :local oldComment [get $existingId comment]
        :if ([:find $oldComment "host="] != nil) do={
            :local oldHost [:pick $oldComment ([:find $oldComment "host="] + 5) [:find $oldComment " ip="]]
            :local oldIP [:pick $oldComment ([:find $oldComment "ip="] + 3) [:find $oldComment " ttl="]]
            :local oldTTL [:tonum [:pick $oldComment ([:find $oldComment "ttl="] + 4) [:len $oldComment]]]

            :if (($oldHost = $leaseHost) and ($oldIP = $leaseIP) and ($oldTTL = $ttl)) do={
                :set needsUpdate false
            }
        }
    }

    :if ($needsUpdate) do={
        :if ([:len $existingId] > 0) do={ remove $existingId }

        /ip dns static add address=$leaseIP name=$fqdn ttl=$ttl comment=($DHCPtag . " host=" . $leaseHost . " ip=" . $leaseIP . " ttl=" . $ttl) disabled=no
        :set newEntriesAdded ($newEntriesAdded + 1) ; # Increment counter for new entries

        :if ([:len $DnsServer] != 0) do={
            :local addUrl ("http://" . $DnsServer . "/api/zones/records/add?domain=" . $fqdn . "&zone=" . $domain . "&type=A&overwrite=true&IPAddress=" . $leaseIP . "&token=" . $ApiToken . "&ttl=" . $ttl . "&comments=Created+by+DHCP2DNS&ptr=true")
            /tool fetch url=$addUrl dst-path=bound.tmp
        }
    }
}

:log info "$LogPrefix: Script finished. Added $newEntriesAdded new DNS entries."
