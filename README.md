# Mikrotik DHCP to Technictium DNS 

This RouterOS script's **primary purpose is to provide Dynamic DNS (DDNS) synchronization to an External DNS Server** (like Technitium DNS) via an HTTP API.

It uses the MikroTik's internal DNS cache (/ip dns static) as a **temporary, authoritative synchronization store** to maintain state and perform change detection. The main goal is to ensure devices receiving dynamic IP addresses are immediately resolvable by their human-assigned names network-wide.

I run this script on a schedule, every 20 mins or so

## **Key Features**

* **Primary External Sync:** Designed specifically to push and delete records on a configured **External DNS Server**.  
* **Hostname Priority:** Prioritizes hostnames based on administrative needs:  
  1. **DHCP Lease Comment** (Highest Priority, for static assignments/friendly names)  
  2. **DHCP Host-Name** (Provided by the client device)  
  3. **IP Fallback** (E.g., 192-168-1-5 if no name is available)  
* **DNS Cleanup:** Automatically removes stale DNS entries from both the router's internal cache and the **external DNS server** when a lease expires or is no longer active.  
* **External Integration:** Includes logic to update a specified external DNS server using a simple HTTP API (e.g., DNS manager, Pi-hole, or other custom APIs).  
* **Low Impact:** Only updates records that have changed, minimizing write operations.  
* **Logging Control:** Includes a boolean flag (enableLogging) to easily toggle verbose logging for debugging or silence the script during production.

## **Configuration**

Before running the script, you must set the following variables at the top of the file:

| Variable | Description |
| :---- | :---- |
| :local DnsServer | The IP and port of your external DNS API server (e.g., "192.168.8.2:5380").  |
| :local ApiToken | The security token required by your external DNS API. |
| :local enableLogging | Set to true to enable detailed logging for troubleshooting; set to false for silent operation (recommended for scheduled runs). |

## **How the Script Works**

The script executes in three distinct steps:

### **Step 1: Build Active Lease Map**

The script iterates through all "bound" DHCP leases and compiles a map of all currently active Fully Qualified Domain Names (FQDNs).

Hostname Determination Logic:  
For each lease, the script determines the hostname using a strict hierarchy, only proceeding to the next step if the previous one yields a non-empty name:

1. Check the **DHCP Lease Comment** field.  
2. If blank, check the **DHCP Host-Name** field.  
3. If still blank, generate a hostname from the **IP Address** (e.g., 192-168-1-5).

**Sanitization:** The selected hostname is then filtered using a highly compatible utility (safeFilterHostname) to remove invalid DNS characters (spaces, symbols) and converted to **lowercase** before being added to the active map.

### **Step 2: Remove Stale DNS Entries**

The script checks all existing records in /ip dns static that were created by this script (identified by the unique DHCPtag).

If an existing static DNS entry's FQDN is **not** found in the activeFQDNs map built in Step 1, it means the lease has expired or been released. The script then:

1. **Removes** the entry from /ip dns static.  
2. **Sends an API call** to the external DNS server to remove the corresponding record (if external DNS is configured).

### **Step 3: Rebuild/Update DNS Entries**

The script iterates through all active DHCP leases again. For each lease, it:

1. **Calculates TTL:** Determines the Time-To-Live (TTL) using the DHCP Server's configured lease time.  
2. **Checks for Updates:** Checks the existing /ip dns static entry's comment field (which stores the previous host, IP, and TTL) to see if the record is current.  
3. **Updates/Adds Record:**  
   * If the record is missing, or if the IP address, hostname, or TTL has changed, the existing static entry is removed and a new one is added.  
   * The :local newEntriesAdded counter is incremented.  
   * An **API call** is made to the external DNS server to add or overwrite the record.

## **Logging**

Two essential log entries are always generated in the MikroTik system log:

* DHCP2DNS: Script started.  
* DHCP2DNS: Script finished. Added X new DNS entries.

If enableLogging is set to true, highly detailed debug information regarding hostname selection, cleanup results, and record removals will also be logged.
