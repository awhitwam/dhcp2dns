# Global Configuration
:local enableLogging false

# External DNS config
:local DnsServer "DNS SERVER HERE - For example; 192.168.1.2:5380"
:local ApiToken "PUT YOUR TOKEN HERE"  

# Internal DNS config
:local DHCPtag "#*# DHCP2DNS"
:local LogPrefix "DHCP2DNS"

# Global list of common generic hostnames to avoid duplicates
:global genericHostnames {"android";"apple-tv";"arlo";"brother";"canon";"chromecast";"dell";"desktop";"epson";"expressif","esp";"esp32";"esp8266";"firetv";"googlehome";"homepod";"hp";"ipad";"iphone";"kindle";"laptop";"lenovo";"lg";"linux";"macbook";"macmini";"nas";"nest";"nintendo";"pc";"playstation";"printer";"qnap";"raspberrypi";"ring";"roku";"samsung";"scanner";"server";"smarttv";"sonos";"switch";"synology";"tablet";"tplink";"ubuntu";"vizio";"windows";"workstation";"wyze";"xbox"}

# Function: makeUniqueHostname
:global makeUniqueHostname do={
    :global enableLogging
    :global LogPrefix
    :global genericHostnames

    :local name [:tostr [:convert $1 transform=lc]]
    :local mac [:convert $2 transform=uc]
    :local isGeneric false

    :if ($enableLogging) do={ :log info ("[$LogPrefix] Evaluating hostname: " . $name) }

    :foreach item in=$genericHostnames do={
        :local itemLower [:tostr [:convert $item transform=lc]]
        :if ($name = $itemLower) do={
            :set isGeneric true
            :if ($enableLogging) do={ :log info ("[$LogPrefix] Exact match found for generic hostname: " . $itemLower) }
        }
    }

    :if ($isGeneric) do={
        :local suffix ([:pick $mac 9 11] . [:pick $mac 12 14])
        :set name ($name . "-" . $suffix)
        :if ($enableLogging) do={ :log info ("[$LogPrefix] Appended MAC suffix: final name = " . $name) }
    } else={
        :if ($enableLogging) do={ :log info ("[$LogPrefix] Hostname is unique, no suffix applied: " . $name) }
    }

    :return $name
}

# Utility: Trim string (removes leading/trailing spaces and null characters)
:local trimString do={
    :local outStr ""
    :for i from=0 to=([:len $inStr] - 1) do={
        :local tmp [:pick $inStr $i]
        :if (($tmp != " ") and ($tmp != "\00")) do={ :set outStr ($outStr . $tmp) }
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
    :local validChars "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
    :local outStr ""
    :for i from=0 to=([:len $inStr] - 1) do={
        :local char [:pick $inStr $i (1 + $i)]
        :if ([:find $validChars $char] >= 0) do={ :set outStr ($outStr . $char) }
    }
    :return $outStr
}

:local newEntriesAdded 0
:log info "$LogPrefix: Script started."

# Step 1: Build active lease map
:local activeFQDNs ""
:foreach leaseId in=[/ip dhcp-server lease find where status="bound"] do={
    :local leaseIP [/ip dhcp-server lease get $leaseId address]
    :local leaseMAC [/ip dhcp-server lease get $leaseId mac-address]
    :local leaseHost ""
    :local rawComment [/ip dhcp-server lease get $leaseId comment]
    :local rawHostName [/ip dhcp-server lease get $leaseId host-name]

    :if ($enableLogging) do={
        :log info ("$LogPrefix: --- Processing Lease $leaseIP ---")
        :log info ("$LogPrefix: $leaseIP | Raw Comment: '$rawComment' | Raw Hostname: '$rawHostName'")
    }

    :local tempName [$trimString inStr=$rawComment]
    :if ([:len $tempName] > 0) do={ :set leaseHost $tempName }

    :if ([:len $leaseHost] = 0) do={
        :local tempName [$trimString inStr=$rawHostName]
        :if ([:len $tempName] > 0) do={ :set leaseHost $tempName }
    }

    :local domain [/ip dhcp-server network get [find $leaseIP in address] domain]
    :set domain [$trimString inStr=$domain]

    :if ([:len $leaseHost] > 0) do={
        :local finalHostName [$safeFilterHostname inStr=$leaseHost]
        :if ([:len $finalHostName] > 0) do={
            :set leaseHost $finalHostName
            :set leaseHost [:convert $leaseHost transform=lc to=raw]
        } else={ :set leaseHost [$ip2Host inStr=$leaseIP] }
    }

    :if ([:len $leaseHost] = 0) do={ :set leaseHost [$ip2Host inStr=$leaseIP] }

    :if ($enableLogging) do={ :log info ("[$LogPrefix] Step1 test: leaseHost=" . $leaseHost . " | MAC=" . $leaseMAC) }

    :set leaseHost [$makeUniqueHostname $leaseHost $leaseMAC]

    :if ([:len $domain] > 0) do={
        :local fqdn ($leaseHost . "." . $domain)
        :set activeFQDNs ($activeFQDNs . "," . $fqdn)
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
        :if ($enableLogging) do={ :log info "$LogPrefix: Removed stale DNS '$fqdn' -> '$address'" }
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
    :local leaseMAC [get $leaseId mac-address]
    :local leaseHost ""

    :local tempName [get $leaseId comment]
    :set tempName [$trimString inStr=$tempName]
    :if ([:len $tempName] > 0) do={ :set leaseHost $tempName }

    :if ([:len $leaseHost] = 0) do={
        :local tempName [get $leaseId host-name]
        :set tempName [$trimString inStr=$tempName]
        :if ([:len $tempName] > 0) do={ :set leaseHost $tempName }
    }

    /ip dhcp-server
    :local ttlRaw [get [find name=$leaseServer] lease-time]
    :local hrs [:tonum [:pick $ttlRaw 0 2]]
    :local min [:tonum [:pick $ttlRaw 3 5]]
    :local sec [:tonum [:pick $ttlRaw 6 8]]
    :local ttl (($hrs * 3600) + ($min * 60) + $sec)

    /ip dhcp-server network
    :local domain [get [find $leaseIP in address] domain]
    :set domain [$trimString inStr=$domain]

    :if ([:len $leaseHost] > 0) do={
        :local finalHostName [$safeFilterHostname inStr=$leaseHost]
        :if ([:len $finalHostName] > 0) do={ :set leaseHost $finalHostName } else={ :set leaseHost "" }
    }

    :if ([:len $leaseHost] = 0) do={ :set leaseHost [$ip2Host inStr=$leaseIP] }

    :set leaseHost [$makeUniqueHostname $leaseHost $leaseMAC]
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
            :if (($oldHost = $leaseHost) and ($oldIP = $leaseIP) and ($oldTTL = $ttl)) do={ :set needsUpdate false }
        }
    }

    :if ($needsUpdate) do={
        :if ([:len $existingId] > 0) do={ remove $existingId }
        /ip dns static add address=$leaseIP name=$fqdn ttl=$ttl comment=($DHCPtag . " host=" . $leaseHost . " ip=" . $leaseIP . " ttl=" . $ttl) disabled=no
        :set newEntriesAdded ($newEntriesAdded + 1)
        :if ([:len $DnsServer] != 0) do={
            :local addUrl ("http://" . $DnsServer . "/api/zones/records/add?domain=" . $fqdn . "&zone=" . $domain . "&type=A&overwrite=true&IPAddress=" . $leaseIP . "&token=" . $ApiToken . "&ttl=" . $ttl . "&comments=Created+by+DHCP2DNS&ptr=true")
            /tool fetch url=$addUrl dst-path=bound.tmp
        }
    }
}

:log info "$LogPrefix: Script finished. Added $newEntriesAdded new DNS entries."
