#!/bin/bash

#
# Binary Download and Install Tool
#
# Downloads a compressed binary archive, verifies its integrity using a checksum
# (sha512, sha256, sha1, or md5), extracts it, and installs specified binaries
# to a destination directory.
#

# Exit on any error, undefined variables, and pipe failures
set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.3"

# Global variables
URL=""
CHECKSUM_URL=""
CHECKSUM_ALGO=""  # Optional: sha512, sha256, sha1, md5 — auto-detected if unset
CHECKSUM_JQ=""    # Optional: jq query to extract "checksum filename" from a JSON checksum file
INSTALL_PATHS=()
INSTALL_TO=""
INSTALL_PACKAGE=false
DOWNLOAD_CACHE_DIR="${DOWNLOAD_CACHE_DIR:-/var/cache/downloads}"
POST_INSTALL_CMDS=()
VERIFY_CMDS=()
DEBUG=false
DRY_RUN=false
PLATFORM="${TARGETPLATFORM:-linux/amd64}"  # Default to linux/amd64 if not set
declare -A PLATFORM_ARCH_MAP
declare -A VARS

#
# Display usage information
#
show_usage() {
	cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Download, verify, and install binary archives with checksum verification.
Supports sha512, sha256, sha1, and md5 checksums (auto-detected by length).
Verification order: sha512 > sha256 > sha1 > md5.

REQUIRED OPTIONS:
	--url URL               Download URL for the archive
	--checksum-url URL      Download URL for the checksum file

OPTIONAL:
	--checksum-algo ALGO   Checksum algorithm: sha512, sha256, sha1, md5, auto
						   Default (auto): auto-detect by digest length; if ambiguous,
						   try in order sha512 > sha256 > sha1 > md5
	--checksum-jq QUERY    jq query applied to a JSON checksum file; must output
	                       lines in "<checksum> <filename>" format compatible with
	                       sha256sum et al. Variable substitution applies to QUERY.
	--install-to DIR       Install to specified directory.
	                       With --install-paths: extract only those paths, installed flat into DIR.
	                       Without --install-paths: extract the full archive tree into DIR.
	                       For direct binaries (non-archive): copy the binary to DIR.
	--install-pkg          Install the downloaded package using system package manager
						   (currently supports .deb packages via dpkg -i)
	--install-paths PATHS   Comma-separated list of paths inside archive to install flat into --install-to
							(can be specified multiple times)
	--var KEY=VALUE        Define a variable for use as {KEY} in URLs and paths
	                       (can be specified multiple times; {os} and {arch} are pre-defined)
	--platform PLATFORM    Target platform (default: ${PLATFORM})
	--platform-arch MAP    Map platform to architecture (format: platform=arch, can be used multiple times)
	--post-install CMD     Shell command to run after installation (before --verify).
	                       Useful for setting permissions, initialising configs, etc.
	                       Variable substitution applies. Executed via 'bash -c'; a
	                       non-zero exit code fails the script with exit code 5.
	--verify CMD           Shell command to run after installation to verify the binary.
	                       Variable substitution applies (e.g. {version}, {arch}).
	                       The command is executed via 'bash -c'; a non-zero exit code
	                       fails the script with exit code 6.
	--verbose, -v          Enable verbose output
	--dry-run              Show what would be done without executing
	--help, -h             Show this help message
	--version              Show version information

NOTE: --install-pkg is mutually exclusive with --install-to and --install-paths

SUPPORTED FORMATS:
	- tar.gz, .tgz (gzip compressed tar)
	- tar.xz (xz compressed tar)
	- zip (ZIP archives)
	- Direct binaries (any other file will be treated as a direct binary)

EXAMPLES:
	# Download and verify only (no extraction/installation)
	$SCRIPT_NAME \\
		--url https://example.com/tool-v1.2.3-linux-amd64.tar.gz \\
		--checksum-url https://example.com/tool-v1.2.3-SHA256SUMS

	# Download, verify, extract and install specific files with platform mapping
	$SCRIPT_NAME \\
		--url https://example.com/tool-v1.2.3-{arch}.tar.gz \\
		--checksum-url https://example.com/tool-v1.2.3-{arch}-SHA256SUMS \\
		--install-paths tool-v1.2.3-{arch}/tool \\
		--install-to /usr/local/bin/ \\
		--platform linux/amd64 \\
		--platform-arch linux/amd64=x64

	# Download, verify, extract and install specific files
	$SCRIPT_NAME \\
		--url https://example.com/tool-v1.2.3-linux-amd64.tar.gz \\
		--checksum-url https://example.com/tool-v1.2.3-SHA256SUMS \\
		--install-paths tool-v1.2.3-linux-amd64/tool \\
		--install-to /usr/local/bin/

	# Extract and install multiple specific files (comma-separated)
	$SCRIPT_NAME \\
		--url https://example.com/suite-v2.0.0-linux-amd64.tar.gz \\
		--checksum-url https://example.com/suite-v2.0.0-SHA256SUMS \\
		--install-paths suite-v2.0.0-linux-amd64/main,suite-v2.0.0-linux-amd64/helper \\
		--install-to /usr/local/bin/ \\
		--verbose

	# Extract and install multiple specific files (multiple --install-paths)
	$SCRIPT_NAME \\
		--url https://example.com/suite-v2.0.0-linux-amd64.tar.gz \\
		--checksum-url https://example.com/suite-v2.0.0-SHA256SUMS \\
		--install-paths suite-v2.0.0-linux-amd64/main \\
		--install-paths suite-v2.0.0-linux-amd64/helper \\
		--install-to /usr/local/bin/ \\
		--verbose

	# Auto-extract and install all files from archive
	$SCRIPT_NAME \\
		--url https://example.com/tools-v1.0.0-linux-amd64.tar.gz \\
		--checksum-url https://example.com/tools-v1.0.0-SHA256SUMS \\
		--install-to /usr/local/bin/

	# Download and install a .deb package directly
	$SCRIPT_NAME \\
		--url https://example.com/package-v1.2.3-amd64.deb \\
		--checksum-url https://example.com/package-v1.2.3-SHA256SUMS \\
		--install-pkg

	# Dry run to see what would happen with package installation
	$SCRIPT_NAME \\
		--url https://example.com/package-v1.2.3-amd64.deb \\
		--checksum-url https://example.com/package-v1.2.3-SHA256SUMS \\
		--install-pkg \\
		--dry-run

	# Download and install a direct binary (like kubectl)
	$SCRIPT_NAME \\
		--url https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl \\
		--checksum-url https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl.sha256 \\
		--install-to /usr/local/bin/

	# Download binary verified via a JSON manifest (e.g. claude-code)
	$SCRIPT_NAME \\
		--url https://example.com/releases/1.0.0/linux-x64/claude \\
		--checksum-url https://example.com/releases/1.0.0/manifest.json \\
		--checksum-jq '.platforms["linux-x64"] | (.checksum + " " + .binary)' \\
		--install-to /usr/local/bin/

	# Verify installed binary reports the expected version
	$SCRIPT_NAME \\
		--url https://example.com/tool-v1.2.3-linux-amd64.tar.gz \\
		--checksum-url https://example.com/tool-v1.2.3-SHA256SUMS \\
		--install-to /usr/local/bin/ \\
		--var version=1.2.3 \\
		--verify 'tool --version | grep -qF "{version}"'

EXIT CODES:
	0   Success
	1   Invalid arguments or missing dependencies
	2   Download failure
	3   Checksum verification failure
	4   Extraction failure
	5   Installation failure
	6   Post-install verification failure

EOF
}

#
# Display version information
#
show_version() {
	echo "$SCRIPT_NAME version $VERSION"
}

#
# Log messages with optional DEBUG control
#
log() {
	local level="$1"
	shift
	
	case "$level" in
		DBG|DEBUG)
			if [[ "$DEBUG" == true ]]; then
				echo "[DBG] $*" >&2
			fi
			;;
		NFO|INFO)
			echo "[NFO] $*" >&2
			;;
		WRN|WARN)
			echo "[WRN] $*" >&2
			;;
		ERR|ERROR)
			echo "[ERR] $*" >&2
			;;
	esac
}

#
# Check if required commands are available
#
check_dependencies() {
	local deps=("curl" "tar" "unzip" "mktemp" "basename" "dirname")
	[[ -n "$CHECKSUM_JQ" ]] && deps+=("jq")
	local missing=()

	for cmd in "${deps[@]}"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done

	# At least one checksum tool must be available
	local available_checksum_tools=()
	for cmd in sha512sum sha256sum sha1sum md5sum; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done

	if [[ ${#missing[@]} -gt 0 ]]; then
		log "ERROR" "Missing required dependencies: ${missing[*]}"
		log "ERROR" "Please install the missing commands and try again"
		exit 1
	fi
}

#
# Validate that required arguments are provided
#
validate_arguments() {
	local errors=()
	
	[[ -z "$URL" ]] && errors+=("--url is required")
	[[ -z "$CHECKSUM_URL" ]] && errors+=("--checksum-url is required")

	if [[ -n "$CHECKSUM_ALGO" ]]; then
		case "$CHECKSUM_ALGO" in
			sha512|sha256|sha1|md5|auto) ;;
			*) errors+=("--checksum-algo must be one of: sha512, sha256, sha1, md5, auto") ;;
		esac
	fi
	
	# Check for mutually exclusive options
	if [[ "$INSTALL_PACKAGE" == true ]]; then
		if [[ -n "$INSTALL_TO" ]]; then
			errors+=("--install-pkg and --install-to are mutually exclusive")
		fi
		if [[ ${#INSTALL_PATHS[@]} -gt 0 ]]; then
			errors+=("--install-pkg and --install-paths are mutually exclusive")
		fi
	fi
	
	if [[ ${#errors[@]} -gt 0 ]]; then
		log "ERROR" "Validation errors:"
		printf '  %s\n' "${errors[@]}" >&2
		echo >&2
		show_usage
		exit 1
	fi
}

#
# Download a file with error handling
#
download_file() {
	local url="$1"
	local output_path="$2"
	local description="$3"
	
	log "INFO" "Downloading $description from: $url"
	log "DEBUG" "Output path: $output_path"
	
	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would download $description"
		return 0
	fi
	
	if ! curl -fsSL "$url" -o "$output_path"; then
		log "ERROR" "Failed to download $description from $url"
		exit 2
	fi
	
	log "DEBUG" "Successfully downloaded $description"
}

#
# Detect checksum algorithm by hex digest length
# sha512=128, sha256=64, sha1=40, md5=32
#
detect_checksum_algo() {
	local checksum="$1"
	local len="${#checksum}"

	case "$len" in
		128) echo "sha512" ;;
		64)  echo "sha256" ;;
		40)  echo "sha1" ;;
		32)  echo "md5" ;;
		*)   echo "" ;;
	esac
}

#
# Return the command name for a given algorithm, or empty if not available
#
checksum_cmd() {
	local algo="$1"
	local cmd

	case "$algo" in
		sha512) cmd="sha512sum" ;;
		sha256) cmd="sha256sum" ;;
		sha1)   cmd="sha1sum" ;;
		md5)    cmd="md5sum" ;;
		*)      return 1 ;;
	esac

	if command -v "$cmd" >/dev/null 2>&1; then
		echo "$cmd"
	fi
}

#
# Extract the expected hex digest for archive_name from a checksum file.
# Supports "digest  filename" format and single-line digest-only format.
# Prints the raw digest on stdout; exits 3 on failure.
#
get_expected_checksum() {
	local checksum_path="$1"
	local archive_name="$2"

	local expected

	# "digest  filename" format
	expected=$(grep -F "$archive_name" "$checksum_path" 2>/dev/null | awk '{print $1}' | head -n1 || true)

	# Single-line digest-only format
	if [[ -z "$expected" ]]; then
		local line_count
		line_count=$(wc -l < "$checksum_path" 2>/dev/null || echo "0")
		if [[ $line_count -le 1 ]]; then
			expected=$(tr -d '[:space:]' < "$checksum_path" 2>/dev/null || true)
		fi
	fi

	if [[ -z "$expected" ]]; then
		log "ERROR" "Could not find checksum for $archive_name in checksum file"
		log "ERROR" "Checksum file contents:"
		head -5 "$checksum_path" >&2
		exit 3
	fi

	echo "$expected"
}

#
# Verify checksum — auto-detects algorithm (sha512 > sha256 > sha1 > md5)
#
verify_checksum() {
	local archive_path="$1"
	local checksum_path="$2"
	local archive_name="$3"

	log "INFO" "Verifying checksum..."

	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would verify checksum"
		return 0
	fi

	if [[ ! -f "$checksum_path" || ! -r "$checksum_path" ]]; then
		log "ERROR" "Checksum file not found or not readable: $checksum_path"
		exit 3
	fi

	local expected_checksum
	expected_checksum=$(get_expected_checksum "$checksum_path" "$archive_name")

	# Determine algorithm: explicit flag > auto-detect by digest length > try-in-order
	local algo=""

	if [[ -n "$CHECKSUM_ALGO" && "$CHECKSUM_ALGO" != "auto" ]]; then
		algo="$CHECKSUM_ALGO"
		log "DEBUG" "Using explicitly specified checksum algorithm: $algo"
	else
		algo=$(detect_checksum_algo "$expected_checksum")
		if [[ -n "$algo" ]]; then
			log "DEBUG" "Auto-detected checksum algorithm from digest length: $algo"
		else
			# Digest length is ambiguous — try each algorithm in preferred order
			log "DEBUG" "Cannot determine algorithm from digest length ${#expected_checksum}; trying in order: sha512, sha256, sha1, md5"
			for try_algo in sha512 sha256 sha1 md5; do
				local try_cmd
				try_cmd=$(checksum_cmd "$try_algo")
				[[ -z "$try_cmd" ]] && continue
				local try_sum
				try_sum=$("$try_cmd" "$archive_path" | awk '{print $1}')
				if [[ "$expected_checksum" == "$try_sum" ]]; then
					algo="$try_algo"
					log "DEBUG" "Matched using algorithm: $algo"
					break
				fi
			done
			if [[ -z "$algo" ]]; then
				log "ERROR" "Checksum verification failed: no algorithm produced a matching digest"
				log "ERROR" "Expected: $expected_checksum"
				exit 3
			fi
		fi
	fi

	local cmd
	cmd=$(checksum_cmd "$algo")
	if [[ -z "$cmd" ]]; then
		log "ERROR" "Required checksum tool not available: ${algo}sum"
		exit 1
	fi

	local calculated_checksum
	calculated_checksum=$("$cmd" "$archive_path" | awk '{print $1}')

	log "DEBUG" "Algorithm:           $algo"
	log "DEBUG" "Expected checksum:   $expected_checksum"
	log "DEBUG" "Calculated checksum: $calculated_checksum"

	if [[ "$expected_checksum" != "$calculated_checksum" ]]; then
		log "ERROR" "${algo} checksum verification failed!"
		log "ERROR" "Expected: $expected_checksum"
		log "ERROR" "Got:      $calculated_checksum"
		exit 3
	fi

	log "INFO" "${algo} checksum verification passed"
}

#
# Check if a file is a supported archive format
#
is_archive() {
	local filename="$1"
	
	case "$filename" in
		*.tar.gz|*.tgz|*.tar.xz|*.zip)
			return 0
			;;
		*)
			return 1
			;;
	esac
}

#
# Install a direct binary file (not an archive)
#
install_direct_binary() {
	local binary_path="$1"
	local dest_path="$2"
	local binary_name="$3"
	
	log "INFO" "Installing direct binary: $binary_name"
	log "DEBUG" "Source: $binary_path"
	log "DEBUG" "Destination: $dest_path"
	
	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would install direct binary $binary_name to $dest_path"
		return 0
	fi
	
	# Create destination directory if needed
	local dest_dir
	dest_dir=$(dirname "$dest_path")
	if ! mkdir -p "$dest_dir"; then
		log "ERROR" "Failed to create destination directory: $dest_dir"
		exit 5
	fi
	
	# When dest_path is a directory, install under binary_name
	if [[ "$dest_path" == */ ]] || [[ -d "$dest_path" ]]; then
		dest_path="${dest_path%/}/$binary_name"
	fi

	# Check for filename conflicts
	if [[ -f "$dest_path" ]]; then
		log "WARN" "File already exists, overwriting: $dest_path"
	fi

	# Copy the binary to destination
	if ! install -C "$binary_path" "$dest_path"; then
		log "ERROR" "Failed to install binary to $dest_path"
		exit 5
	fi

	log "INFO" "Successfully installed direct binary: $(basename "$dest_path")"
}

#
# Extract archive based on file extension
#
extract_archive() {
	local archive_path="$1"
	local extract_dir="$2"
	local archive_name="$3"
	
	log "INFO" "Extracting archive: $archive_name"
	log "DEBUG" "Extract directory: $extract_dir"
	
	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would extract $archive_name"
		return 0
	fi
	
	case "$archive_name" in
		*.tar.gz|*.tgz)
			log "DEBUG" "Detected gzip compressed tar archive"
			if ! tar -xzf "$archive_path" -C "$extract_dir"; then
				log "ERROR" "Failed to extract tar.gz archive"
				exit 4
			fi
			;;
		*.tar.xz)
			log "DEBUG" "Detected xz compressed tar archive"
			if ! tar -xJf "$archive_path" -C "$extract_dir"; then
				log "ERROR" "Failed to extract tar.xz archive"
				exit 4
			fi
			;;
		*.zip)
			log "DEBUG" "Detected ZIP archive"
			if ! unzip -q "$archive_path" -d "$extract_dir"; then
				log "ERROR" "Failed to extract ZIP archive"
				exit 4
			fi
			;;
		*)
			log "ERROR" "Unsupported archive format: $archive_name"
			log "ERROR" "Supported formats: tar.gz, .tgz, .tar.xz, .zip"
			exit 4
			;;
	esac
	
	log "DEBUG" "Archive extracted successfully"
}

#
# Extract only the paths in INSTALL_PATHS from the archive into extract_dir.
# Literal paths (no glob chars) rely on tar's built-in directory recursion so
# a bare name like "opencode" extracts the whole subtree.
# Glob patterns (containing *, ?, or [) are passed with --wildcards.
#
extract_selective() {
	local archive_path="$1"
	local archive_name="$2"
	local extract_dir="$3"

	log "INFO" "Selectively extracting from: $archive_name"
	log "DEBUG" "Patterns: ${INSTALL_PATHS[*]}"

	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would extract: ${INSTALL_PATHS[*]}"
		return 0
	fi

	if ! mkdir -p "$extract_dir"; then
		log "ERROR" "Failed to create extraction directory: $extract_dir"
		exit 4
	fi

	# Split patterns into literal vs glob so each group gets the right tar flags
	local -a literal_patterns=()
	local -a glob_patterns=()
	for pattern in "${INSTALL_PATHS[@]}"; do
		if [[ "$pattern" == *[\*\?\[]* ]]; then
			glob_patterns+=("$pattern")
		else
			literal_patterns+=("$pattern")
		fi
	done

	case "$archive_name" in
		*.tar.gz|*.tgz|*.tar.xz)
			local flag
			[[ "$archive_name" == *.tar.xz ]] && flag="-xJf" || flag="-xzf"
			if [[ ${#literal_patterns[@]} -gt 0 ]]; then
				if ! tar "$flag" "$archive_path" -C "$extract_dir" "${literal_patterns[@]}"; then
					log "ERROR" "Failed to extract from archive: ${literal_patterns[*]}"
					exit 4
				fi
			fi
			if [[ ${#glob_patterns[@]} -gt 0 ]]; then
				for pattern in "${glob_patterns[@]}"; do
					local tar_err
					if ! tar_err=$(tar "$flag" "$archive_path" -C "$extract_dir" --wildcards "$pattern" 2>&1); then
						if echo "$tar_err" | grep -qF "Not found in archive"; then
							log "INFO" "No entries matched glob pattern (skipping): $pattern"
						else
							log "ERROR" "Failed to extract glob pattern from archive: $pattern"
							echo "$tar_err" >&2
							exit 4
						fi
					fi
				done
			fi
			;;
		*.zip)
			if ! unzip -q "$archive_path" "${INSTALL_PATHS[@]}" -d "$extract_dir"; then
				log "ERROR" "Failed to selectively extract from zip archive"
				exit 4
			fi
			;;
		*)
			log "ERROR" "Unsupported archive format for selective extraction: $archive_name"
			exit 4
			;;
	esac
}

#
# Extract archive to dest preserving the full directory tree
#
install_tree() {
	local archive_path="$1"
	local dest_dir="$2"
	local archive_name="$3"

	log "INFO" "Extracting archive tree to: $dest_dir"

	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would extract $archive_name to $dest_dir"
		return 0
	fi

	if ! mkdir -p "$dest_dir"; then
		log "ERROR" "Failed to create destination directory: $dest_dir"
		exit 5
	fi

	case "$archive_name" in
		*.tar.gz|*.tgz)
			if ! tar -xzf "$archive_path" -C "$dest_dir"; then
				log "ERROR" "Failed to extract tar.gz archive to $dest_dir"
				exit 4
			fi
			;;
		*.tar.xz)
			if ! tar -xJf "$archive_path" -C "$dest_dir"; then
				log "ERROR" "Failed to extract tar.xz archive to $dest_dir"
				exit 4
			fi
			;;
		*.zip)
			if ! unzip -q "$archive_path" -d "$dest_dir"; then
				log "ERROR" "Failed to extract zip archive to $dest_dir"
				exit 4
			fi
			;;
		*)
			log "ERROR" "Unsupported archive format for tree extraction: $archive_name"
			exit 4
			;;
	esac

	log "INFO" "Archive extracted to $dest_dir"
}

#
# Install selected paths from an extracted archive into dest_dir.
# Each entry in INSTALL_PATHS is a shell glob relative to the archive root.
# Matched files are installed flat (basename only) into dest_dir.
# Matched directories are copied as a tree (dest_dir/<dirname>).
#
install_binaries() {
	local extract_dir="$1"
	local dest_dir="$2"

	log "INFO" "Installing to: $dest_dir"
	log "DEBUG" "Patterns: ${INSTALL_PATHS[*]}"

	if [[ "$DRY_RUN" == false ]] && ! mkdir -p "$dest_dir"; then
		log "ERROR" "Failed to create destination directory: $dest_dir"
		exit 5
	fi

	local installed_count=0

	for path_pattern in "${INSTALL_PATHS[@]}"; do
		local -a matches
		mapfile -t matches < <(compgen -G "$extract_dir/$path_pattern" 2>/dev/null)

		if [[ ${#matches[@]} -eq 0 ]]; then
			log "ERROR" "No match for pattern in archive: $path_pattern"
			log "ERROR" "Archive contents (first 20):"
			find "$extract_dir" -maxdepth 3 | sed "s|^$extract_dir/\{0,1\}||" | grep -v '^$' | head -20 | sed 's/^/  /' >&2
			exit 5
		fi

		for match in "${matches[@]}"; do
			local item_name
			item_name=$(basename "$match")

			# .* globs include . and .. — skip them
			[[ "$item_name" == "." || "$item_name" == ".." ]] && continue

			if [[ "$DRY_RUN" == true ]]; then
				log "INFO" "[DRY RUN] Would install: ${match#$extract_dir/} -> $dest_dir/$item_name"
				continue
			fi

			if [[ -d "$match" ]]; then
				if [[ -e "$dest_dir/$item_name" ]]; then
					log "WARN" "Already exists, overwriting: $dest_dir/$item_name"
					rm -rf "$dest_dir/$item_name"
				fi
				if ! cp -r "$match" "$dest_dir/$item_name"; then
					log "ERROR" "Failed to copy directory: $match -> $dest_dir/$item_name"
					exit 5
				fi
				log "INFO" "Installed directory: $item_name"
			else
				local dest_path="$dest_dir/$item_name"
				if [[ -e "$dest_path" ]]; then
					log "WARN" "File already exists, overwriting: $dest_path"
				fi
				if ! install -C "$match" "$dest_path"; then
					log "ERROR" "Failed to install: $match -> $dest_path"
					exit 5
				fi
				if [[ -x "$match" ]] || [[ "${dest_dir%/}" =~ /bin$ ]]; then
					chmod +x "$dest_path" || log "WARN" "Failed to set executable bit on $dest_path"
				fi
				log "INFO" "Installed: $item_name"
			fi
			installed_count=$((installed_count + 1))
		done
	done

	log "INFO" "Successfully installed $installed_count items"
}

#
# Install a package using the system package manager
#
install_package() {
	local package_path="$1"
	local package_name="$2"
	
	log "INFO" "Installing package: $package_name"
	log "DEBUG" "Package path: $package_path"
	
	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would install package $package_name"
		return 0
	fi
	
	# Detect package format and install accordingly
	case "$package_name" in
		*.deb)
			log "DEBUG" "Detected Debian package format"
			if ! command -v dpkg >/dev/null 2>&1; then
				log "ERROR" "dpkg is not available - cannot install .deb packages"
				exit 5
			fi
			
			log "INFO" "Installing .deb package using dpkg..."
			# Use sudo if available, otherwise run dpkg directly (useful in Docker containers)
			local dpkg_cmd="dpkg"
			if command -v sudo >/dev/null 2>&1 && [[ $EUID -ne 0 ]]; then
				dpkg_cmd="sudo dpkg"
			fi
			
			if ! $dpkg_cmd -i "$package_path"; then
				log "ERROR" "Failed to install .deb package: $package_name"
				if command -v sudo >/dev/null 2>&1; then
					log "ERROR" "You may need to run: sudo apt-get install -f"
				else
					log "ERROR" "You may need to run: apt-get install -f"
				fi
				exit 5
			fi
			;;
		*)
			log "ERROR" "Unsupported package format: $package_name"
			log "ERROR" "Currently supported formats: .deb"
			exit 5
			;;
	esac
	
	log "INFO" "Package installed successfully: $package_name"
}

#
# Run an arbitrary post-install command (before verification)
#
run_post_install() {
	local cmd="$1"

	log "INFO" "Running post-install command..."
	log "DEBUG" "Post-install command: $cmd"

	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would run post-install: $cmd"
		return 0
	fi

	local output
	if ! output=$(bash -c "$cmd" 2>&1); then
		log "ERROR" "Post-install command failed (exit code $?)"
		log "ERROR" "Command: $cmd"
		[[ -n "$output" ]] && log "ERROR" "Output: $output"
		exit 5
	fi

	log "DEBUG" "Post-install output: $output"
	log "INFO" "Post-install command completed"
}

#
# Run the post-install verification command
#
run_verify() {
	local cmd="$1"

	log "INFO" "Running post-install verification..."
	log "DEBUG" "Verify command: $cmd"

	if [[ "$DRY_RUN" == true ]]; then
		log "INFO" "[DRY RUN] Would run verify: $cmd"
		return 0
	fi

	local output
	if ! output=$(bash -c "$cmd" 2>&1); then
		log "ERROR" "Post-install verification failed (exit code $?)"
		log "ERROR" "Command: $cmd"
		[[ -n "$output" ]] && log "ERROR" "Output: $output"
		exit 6
	fi

	log "DEBUG" "Verification output: $output"
	log "INFO" "Post-install verification passed"
}

#
# Parse command line arguments
#
parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case $1 in
			--url)
				[[ -z "${2:-}" ]] && { log "ERROR" "--url requires a value"; exit 1; }
				URL="$2"
				shift 2
				;;
			--checksum-url)
				[[ -z "${2:-}" ]] && { log "ERROR" "--checksum-url requires a value"; exit 1; }
				CHECKSUM_URL="$2"
				shift 2
				;;
			--checksum-algo)
				[[ -z "${2:-}" ]] && { log "ERROR" "--checksum-algo requires a value"; exit 1; }
				CHECKSUM_ALGO="$2"
				shift 2
				;;
			--checksum-jq)
				[[ -z "${2:-}" ]] && { log "ERROR" "--checksum-jq requires a value"; exit 1; }
				CHECKSUM_JQ="$2"
				shift 2
				;;
			--install-paths)
				[[ -z "${2:-}" ]] && { log "ERROR" "--install-paths requires a value"; exit 1; }
				# Split comma-separated paths and add them to the array
				local paths_to_add=()
				IFS=',' read -r -a paths_to_add <<< "$2"
				INSTALL_PATHS+=("${paths_to_add[@]}")
				shift 2
				;;
			--install-to)
				[[ -z "${2:-}" ]] && { log "ERROR" "--install-to requires a value"; exit 1; }
				INSTALL_TO="$2"
				shift 2
				;;
			--install-pkg)
				INSTALL_PACKAGE=true
				shift
				;;
			--post-install)
				[[ -z "${2:-}" ]] && { log "ERROR" "--post-install requires a value"; exit 1; }
				POST_INSTALL_CMDS+=("$2")
				shift 2
				;;
			--verify)
				[[ -z "${2:-}" ]] && { log "ERROR" "--verify requires a value"; exit 1; }
				VERIFY_CMDS+=("$2")
				shift 2
				;;
			--verbose|-v)
				DEBUG=true
				shift
				;;
			--platform)
				[[ -z "${2:-}" ]] && { log "ERROR" "--platform requires a value"; exit 1; }
				PLATFORM="$2"
				shift 2
				;;
			--platform-arch)
				[[ -z "${2:-}" ]] && { log "ERROR" "--platform-arch requires a value"; exit 1; }
				if [[ "$2" =~ ^(.+)=(.+)$ ]]; then
					PLATFORM_ARCH_MAP["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
				else
					log "ERROR" "Invalid platform-arch format: $2 (expected: platform=arch)"
					exit 1
				fi
				shift 2
				;;
			--var)
				[[ -z "${2:-}" ]] && { log "ERROR" "--var requires a value"; exit 1; }
				if [[ "$2" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
					VARS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
				else
					log "ERROR" "Invalid --var format: $2 (expected: key=value, key must start with a letter or underscore)"
					exit 1
				fi
				shift 2
				;;
			--dry-run)
				DRY_RUN=true
				shift
				;;
			--help|-h)
				show_usage
				exit 0
				;;
			--version)
				show_version
				exit 0
				;;
			-*)
				log "ERROR" "Unknown option: $1"
				echo >&2
				show_usage
				exit 1
				;;
			*)
				log "ERROR" "Unexpected argument: $1"
				echo >&2
				show_usage
				exit 1
				;;
		esac
	done
}

#
# Apply all variable substitutions ({key} -> value) to a string
#
apply_vars() {
	local value="$1"
	local key
	for key in "${!VARS[@]}"; do
		value="${value//\{$key\}/${VARS[$key]}}"
	done
	echo "$value"
}

#
# Main execution function
#
main() {
	# Parse command line arguments
	parse_arguments "$@"
	
	# Determine architecture from platform
	local arch=""
	if [[ -n "${PLATFORM_ARCH_MAP[$PLATFORM]:-}" ]]; then
		arch="${PLATFORM_ARCH_MAP[$PLATFORM]}"
	else
		# Extract architecture part from platform (everything after the last /)
		arch="${PLATFORM##*/}"
	fi

	local os="${PLATFORM%%/*}"

	# Populate pre-defined vars (os and arch take precedence over any --var with the same name)
	VARS[os]="$os"
	VARS[arch]="$arch"

	# Apply variable substitutions to all relevant parameters
	URL=$(apply_vars "$URL")
	CHECKSUM_URL=$(apply_vars "$CHECKSUM_URL")
	CHECKSUM_JQ=$(apply_vars "$CHECKSUM_JQ")
	INSTALL_TO=$(apply_vars "$INSTALL_TO")
	local updated_post_install_cmds=()
	for cmd in "${POST_INSTALL_CMDS[@]}"; do
		updated_post_install_cmds+=("$(apply_vars "$cmd")")
	done
	POST_INSTALL_CMDS=("${updated_post_install_cmds[@]}")
	local updated_verify_cmds=()
	for cmd in "${VERIFY_CMDS[@]}"; do
		updated_verify_cmds+=("$(apply_vars "$cmd")")
	done
	VERIFY_CMDS=("${updated_verify_cmds[@]}")

	local updated_install_paths=()
	for path in "${INSTALL_PATHS[@]}"; do
		updated_install_paths+=("$(apply_vars "$path")")
	done
	INSTALL_PATHS=("${updated_install_paths[@]}")
	
	# Check dependencies and validate arguments
	check_dependencies
	validate_arguments
	
	# Show configuration in DEBUG mode
	if [[ "$DEBUG" == true ]]; then
		log "DEBUG" "Configuration:"
		log "DEBUG" "  Dry run: $DRY_RUN"
		log "DEBUG" "  Target: $PLATFORM"
		log "DEBUG" "   - OS: $os"
		log "DEBUG" "   - Arch: $arch"
		if [[ ${#VARS[@]} -gt 2 ]]; then  # more than just os and arch
			log "DEBUG" "  Vars:"
			for key in "${!VARS[@]}"; do
				[[ "$key" == "os" || "$key" == "arch" ]] && continue
				log "DEBUG" "   - {$key}: ${VARS[$key]}"
			done
		fi
		log "DEBUG" "  URL:"
		log "DEBUG" "   - Archive: $URL"
		log "DEBUG" "   - Checksum: $CHECKSUM_URL"
		log "DEBUG" "   - Algo: ${CHECKSUM_ALGO:-auto}"
		log "DEBUG" "  Install:"
		log "DEBUG" "   - Dest: $INSTALL_TO"
		log "DEBUG" "   - Paths: ${INSTALL_PATHS[*]}"
		log "DEBUG" "   - Package: $INSTALL_PACKAGE"
	fi
	
	# Set up temporary workspace
	local temp_dir
	temp_dir=$(mktemp -d)
	
	# Ensure cleanup on exit (use a more robust cleanup function)
	cleanup() {
		if [[ -n "${temp_dir:-}" && -d "$temp_dir" ]]; then
			rm -rf "$temp_dir"
		fi
	}
	trap cleanup EXIT
	
	# Derive file names and paths
	local archive_name checksum_name archive_path checksum_path extract_dir
	archive_name=$(basename "$URL")
	checksum_name=$(basename "$CHECKSUM_URL")
	archive_path="$temp_dir/$archive_name"
	checksum_path="$temp_dir/$checksum_name"
	extract_dir="$temp_dir/extracted"
	
	log "DEBUG" "Temporary directory: $temp_dir"
	
	# Create extraction directory
	if [[ "$DRY_RUN" == false ]]; then
		mkdir -p "$extract_dir"
	fi
	
	# Execute main workflow
	# Checksum is always downloaded fresh — it drives cache validation below
	download_file "$CHECKSUM_URL" "$checksum_path" "checksum file"

	# Transform JSON checksum file with jq if requested
	if [[ -n "$CHECKSUM_JQ" ]]; then
		log "INFO" "Transforming JSON checksum file with jq..."
		log "DEBUG" "jq query: $CHECKSUM_JQ"
		if [[ "$DRY_RUN" == true ]]; then
			log "INFO" "[DRY RUN] Would run: jq -r '$CHECKSUM_JQ' $checksum_path"
		else
			local jq_output
			if ! jq_output=$(jq -r "$CHECKSUM_JQ" "$checksum_path" 2>&1); then
				log "ERROR" "jq transformation failed: $jq_output"
				exit 3
			fi
			if [[ -z "$jq_output" || "$jq_output" == "null" ]]; then
				log "ERROR" "jq query returned no output — check your --checksum-jq expression"
				exit 3
			fi
			echo "$jq_output" > "$checksum_path"
			log "DEBUG" "Transformed checksum content: $jq_output"
		fi
	fi

	# Content-addressable cache: the expected checksum is the cache key.
	# Downloads land in a .tmp file first; only promoted to the cache after the
	# checksum passes, so a bad download never poisons it. Cache hits need no
	# re-verification — the filename is the proof.
	if [[ "$DRY_RUN" == true ]]; then
		download_file "$URL" "$archive_path" "archive"
		verify_checksum "$archive_path" "$checksum_path" "$archive_name"
	else
		local expected_checksum
		expected_checksum=$(get_expected_checksum "$checksum_path" "$archive_name")
		local cache_file="$DOWNLOAD_CACHE_DIR/$expected_checksum"

		if [[ ! -f "$cache_file" ]]; then
			mkdir -p "$DOWNLOAD_CACHE_DIR"
			# Per-entry advisory lock: multiple concurrent builds share the cache
			# (sharing=shared on the mount); flock serialises downloads of the same
			# entry while letting unrelated entries proceed in parallel.
			# Double-check after acquiring: a concurrent build may have populated
			# the cache while we waited for the lock.
			(
				flock 9
				if [[ ! -f "$cache_file" ]]; then
					local tmp_file="${cache_file}.tmp"
					download_file "$URL" "$tmp_file" "archive"
					verify_checksum "$tmp_file" "$checksum_path" "$archive_name"
					mv "$tmp_file" "$cache_file"
				else
					log "INFO" "Cache hit (after lock): $archive_name ($expected_checksum)"
				fi
			) 9>"${cache_file}.lock"
		else
			log "INFO" "Cache hit: $archive_name ($expected_checksum)"
		fi
		archive_path="$cache_file"
	fi
	
	if [[ "$INSTALL_PACKAGE" == true ]]; then
		install_package "$archive_path" "$archive_name"
		log "INFO" "Download, verification, and package installation completed successfully"
	elif [[ -n "$INSTALL_TO" ]]; then
		if is_archive "$archive_name"; then
			if [[ ${#INSTALL_PATHS[@]} -gt 0 ]]; then
				# Selective extraction — only decompress the requested paths
				extract_selective "$archive_path" "$archive_name" "$extract_dir"
				install_binaries "$extract_dir" "$INSTALL_TO"
			else
				# No specific paths — extract full tree into INSTALL_TO
				install_tree "$archive_path" "$INSTALL_TO" "$archive_name"
			fi
			log "INFO" "Download, verification, and extraction completed successfully"
		else
			# Direct binary (not an archive)
			install_direct_binary "$archive_path" "$INSTALL_TO" "$archive_name"
			log "INFO" "Download, verification, and direct installation completed successfully"
		fi
	else
		log "INFO" "Download and verification completed successfully"
		log "INFO" "Archive verified and ready at: $archive_path"
		log "INFO" "Use --install-to to extract and install files, or --install-pkg for package installation"
	fi

	for cmd in "${POST_INSTALL_CMDS[@]}"; do
		run_post_install "$cmd"
	done

	for cmd in "${VERIFY_CMDS[@]}"; do
		run_verify "$cmd"
	done
}

# Execute main function with all arguments
main "$@"
