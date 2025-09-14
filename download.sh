#!/bin/bash

#
# Binary Download and Install Tool
#
# Downloads a compressed binary archive, verifies its integrity using SHA256,
# extracts it, and installs specified binaries to a destination directory.
#
# Author: Auto-generated improvement script
# Version: 0.1.0
#

# Exit on any error, undefined variables, and pipe failures
set -euo pipefail

# Configuration
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="2.0"

# Global variables
URL=""
SHASUM_URL=""
INSTALL_PATHS=()
INSTALL_TO=""
INSTALL_PACKAGE=false
DEBUG=false
DRY_RUN=false

#
# Display usage information
#
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS]

Download, verify, and install binary archives with SHA256 verification.

REQUIRED OPTIONS:
    --url URL               Download URL for the archive
    --shasum-url URL        Download URL for the SHA256SUMS file

OPTIONAL:
    --install-to DIR       Extract archive and install files to specified directory
    --install-pkg          Install the downloaded package using system package manager
                           (currently supports .deb packages via dpkg -i)
    --install-paths PATHS   Comma-separated list of paths inside archive to install
                            (can be specified multiple times; if not specified, all files will be installed)
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
        --shasum-url https://example.com/tool-v1.2.3-SHA256SUMS

    # Download, verify, extract and install specific files
    $SCRIPT_NAME \\
        --url https://example.com/tool-v1.2.3-linux-amd64.tar.gz \\
        --shasum-url https://example.com/tool-v1.2.3-SHA256SUMS \\
        --install-paths tool-v1.2.3-linux-amd64/tool \\
        --install-to /usr/local/bin

    # Extract and install multiple specific files (comma-separated)
    $SCRIPT_NAME \\
        --url https://example.com/suite-v2.0.0-linux-amd64.tar.gz \\
        --shasum-url https://example.com/suite-v2.0.0-SHA256SUMS \\
        --install-paths suite-v2.0.0-linux-amd64/main,suite-v2.0.0-linux-amd64/helper \\
        --install-to /usr/local/bin \\
        --verbose

    # Extract and install multiple specific files (multiple --install-paths)
    $SCRIPT_NAME \\
        --url https://example.com/suite-v2.0.0-linux-amd64.tar.gz \\
        --shasum-url https://example.com/suite-v2.0.0-SHA256SUMS \\
        --install-paths suite-v2.0.0-linux-amd64/main \\
        --install-paths suite-v2.0.0-linux-amd64/helper \\
        --install-to /usr/local/bin \\
        --verbose

    # Auto-extract and install all files from archive
    $SCRIPT_NAME \\
        --url https://example.com/tools-v1.0.0-linux-amd64.tar.gz \\
        --shasum-url https://example.com/tools-v1.0.0-SHA256SUMS \\
        --install-to /usr/local/bin

    # Download and install a .deb package directly
    $SCRIPT_NAME \\
        --url https://example.com/package-v1.2.3-amd64.deb \\
        --shasum-url https://example.com/package-v1.2.3-SHA256SUMS \\
        --install-pkg

    # Dry run to see what would happen with package installation
    $SCRIPT_NAME \\
        --url https://example.com/package-v1.2.3-amd64.deb \\
        --shasum-url https://example.com/package-v1.2.3-SHA256SUMS \\
        --install-pkg \\
        --dry-run

    # Download and install a direct binary (like kubectl)
    $SCRIPT_NAME \\
        --url https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl \\
        --shasum-url https://dl.k8s.io/release/v1.28.0/bin/linux/amd64/kubectl.sha256 \\
        --install-to /usr/local/bin/kubectl

EXIT CODES:
    0   Success
    1   Invalid arguments or missing dependencies
    2   Download failure
    3   SHA256 verification failure
    4   Extraction failure
    5   Installation failure

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
    local deps=("curl" "sha256sum" "tar" "unzip" "mktemp" "basename" "dirname")
    local missing=()
    
    for cmd in "${deps[@]}"; do
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
    [[ -z "$SHASUM_URL" ]] && errors+=("--shasum-url is required")
    
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
# Verify SHA256 checksum
#
verify_checksum() {
    local archive_path="$1"
    local shasum_path="$2"
    local archive_name="$3"
    
    log "INFO" "Verifying SHA256 checksum..."
    
    if [[ "$DRY_RUN" == true ]]; then
        log "INFO" "[DRY RUN] Would verify SHA256 checksum"
        return 0
    fi
    
    local expected_shasum
    
    log "DEBUG" "Checking SHA256 file format..."
    
    # First, try to find the checksum with filename (format: "checksum  filename")
    log "DEBUG" "Attempting to find checksum with filename pattern..."
    expected_shasum=$(grep -F "$archive_name" "$shasum_path" 2>/dev/null | awk '{print $1}' | head -n1 || true)
    
    log "DEBUG" "Grep result for filename pattern: '$expected_shasum'"
    
    # If not found, check if the file contains only a checksum (no filename)
    if [[ -z "$expected_shasum" ]]; then
        log "DEBUG" "No filename pattern found, checking for checksum-only format..."
        
        # Check if the file exists and is readable
        if [[ -f "$shasum_path" && -r "$shasum_path" ]]; then
            log "DEBUG" "SHA256 file exists and is readable"
            
            # Check if the file contains a single line with just the checksum
            local line_count
            line_count=$(wc -l < "$shasum_path" 2>/dev/null || echo "0")
            
            log "DEBUG" "SHA256 file line count: $line_count"
            
            # Handle both single line with newline (count=1) and single line without newline (count=0)
            if [[ $line_count -le 1 ]]; then
                expected_shasum=$(cat "$shasum_path" 2>/dev/null | tr -d '[:space:]')
                if [[ -n "$expected_shasum" ]]; then
                    log "DEBUG" "Using checksum-only format from SHA256 file: '$expected_shasum'"
                fi
            fi
        else
            log "ERROR" "SHA256 file not found or not readable: $shasum_path"
            exit 3
        fi
    fi
    
    if [[ -z "$expected_shasum" ]]; then
        log "ERROR" "Could not find checksum for $archive_name in SHA256SUMS file"
        log "ERROR" "SHA256SUMS file contents:"
        head -5 "$shasum_path" >&2
        exit 3
    fi
    
    local calculated_shasum
    calculated_shasum=$(sha256sum "$archive_path" | awk '{print $1}')
    
    log "DEBUG" "Expected SHA256:   $expected_shasum"
    log "DEBUG" "Calculated SHA256: $calculated_shasum"
    
    if [[ "$expected_shasum" != "$calculated_shasum" ]]; then
        log "ERROR" "SHA256 checksum verification failed!"
        log "ERROR" "Expected: $expected_shasum"
        log "ERROR" "Got:      $calculated_shasum"
        exit 3
    fi
    
    log "INFO" "SHA256 checksum verification passed"
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
    
    # Check for filename conflicts
    if [[ -f "$dest_path" ]]; then
        log "WARN" "File already exists, overwriting: $dest_path"
    fi
    
    # Copy the binary to destination
    if ! cp "$binary_path" "$dest_path"; then
        log "ERROR" "Failed to install binary to $dest_path"
        exit 5
    fi
    
    # Set executable permission
    if ! chmod +x "$dest_path"; then
        log "ERROR" "Failed to set executable permission on $dest_path"
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
# Install binaries from extracted archive
#
install_binaries() {
    local extract_dir="$1"
    local dest_dir="$2"
    
    log "INFO" "Installing binaries to: $dest_dir"
    
    # Create destination directory if it doesn't exist
    if [[ "$DRY_RUN" == false ]] && ! mkdir -p "$dest_dir"; then
        log "ERROR" "Failed to create destination directory: $dest_dir"
        exit 5
    fi
    
    local files_to_install=()
    local installed_count=0
    
    # Determine what files to install
    if [[ ${#INSTALL_PATHS[@]} -gt 0 ]]; then
        # Use specified paths
        log "DEBUG" "Installing specified paths: ${INSTALL_PATHS[*]}"
        files_to_install=("${INSTALL_PATHS[@]}")
        
        if [[ "$DRY_RUN" == true ]]; then
            log "INFO" "[DRY RUN] Would install ${#files_to_install[@]} specified files"
            for path in "${files_to_install[@]}"; do
                local basename_file
                basename_file=$(basename "$path")
                log "INFO" "[DRY RUN] Would install: $path -> $dest_dir/$basename_file"
            done
            return 0
        fi
    else
        # Auto-discover executable files in the archive
        log "DEBUG" "Auto-discovering executable files in archive"
        
        if [[ "$DRY_RUN" == true ]]; then
            log "INFO" "[DRY RUN] Would auto-discover and install all executable files"
            return 0
        fi
        
        # Find all files in the extract directory (install all files by default)
        local all_files=()
        while IFS= read -r -d '' file; do
            # Get relative path from extract_dir
            local rel_path="${file#$extract_dir/}"
            
            # Skip if it's a directory or hidden file
            if [[ -f "$file" && ! "$rel_path" =~ ^\. ]]; then
                all_files+=("$rel_path")
            fi
        done < <(find "$extract_dir" -type f -print0 2>/dev/null)
        
        files_to_install=("${all_files[@]}")
        log "INFO" "Auto-discovered ${#files_to_install[@]} files to install"
        
        if [[ ${#files_to_install[@]} -eq 0 ]]; then
            log "ERROR" "No files found in archive to install"
            exit 5
        fi
    fi
    
    # Install the files
    for path in "${files_to_install[@]}"; do
        local basename_file
        basename_file=$(basename "$path")
        local source_path="$extract_dir/$path"
        local dest_path="$dest_dir/$basename_file"
        
        log "DEBUG" "Installing: $path -> $dest_path"
        
        if [[ ! -f "$source_path" ]]; then
            log "ERROR" "Path not found in archive: $path"
            log "ERROR" "Available files in extract directory:"
            find "$extract_dir" -type f | head -10 | sed 's/^/  /' >&2
            exit 5
        fi
        
        # Check for filename conflicts
        if [[ -f "$dest_path" ]]; then
            log "WARN" "File already exists, overwriting: $dest_path"
        fi
        
        if ! cp "$source_path" "$dest_path"; then
            log "ERROR" "Failed to copy $path to $dest_path"
            exit 5
        fi
        
        # Set executable permission if the source file was executable
        # or if we're installing to a typical binary directory
        if [[ -x "$source_path" ]] || [[ "$dest_dir" =~ bin$ ]]; then
            if ! chmod +x "$dest_path"; then
                log "WARN" "Failed to set executable permission on $dest_path"
            fi
        fi
        
        log "INFO" "Installed: $basename_file"
        installed_count=$((installed_count + 1))
    done
    
    log "INFO" "Successfully installed $installed_count files"
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
            --shasum-url)
                [[ -z "${2:-}" ]] && { log "ERROR" "--shasum-url requires a value"; exit 1; }
                SHASUM_URL="$2"
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
            --verbose|-v)
                DEBUG=true
                shift
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
# Main execution function
#
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Check dependencies and validate arguments
    check_dependencies
    validate_arguments
    
    # Show configuration in DEBUG mode
    if [[ "$DEBUG" == true ]]; then
        log "DEBUG" "Configuration:"
        log "DEBUG" "  Archive URL: $URL"
        log "DEBUG" "  SHA256 URL:  $SHASUM_URL"
        log "DEBUG" "  Install to: $INSTALL_TO"
        log "DEBUG" "  Install package: $INSTALL_PACKAGE"
        log "DEBUG" "  Install paths: ${INSTALL_PATHS[*]}"
        log "DEBUG" "  Dry run: $DRY_RUN"
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
    local archive_name shasum_name archive_path shasum_path extract_dir
    archive_name=$(basename "$URL")
    shasum_name=$(basename "$SHASUM_URL")
    archive_path="$temp_dir/$archive_name"
    shasum_path="$temp_dir/$shasum_name"
    extract_dir="$temp_dir/extracted"
    
    log "DEBUG" "Temporary directory: $temp_dir"
    
    # Create extraction directory
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$extract_dir"
    fi
    
    # Execute main workflow
    download_file "$URL" "$archive_path" "archive"
    download_file "$SHASUM_URL" "$shasum_path" "SHA256SUMS"
    verify_checksum "$archive_path" "$shasum_path" "$archive_name"
    
    if [[ "$INSTALL_PACKAGE" == true ]]; then
        install_package "$archive_path" "$archive_name"
        log "INFO" "Download, verification, and package installation completed successfully"
    elif [[ -n "$INSTALL_TO" ]]; then
        # Check if the downloaded file is a direct binary or an archive
        if is_archive "$archive_name"; then
            extract_archive "$archive_path" "$extract_dir" "$archive_name"
            install_binaries "$extract_dir" "$INSTALL_TO"
            log "INFO" "Download, verification, extraction and installation completed successfully"
        else
            # Handle direct binary installation
            install_direct_binary "$archive_path" "$INSTALL_TO" "$archive_name"
            log "INFO" "Download, verification, and direct installation completed successfully"
        fi
    else
        log "INFO" "Download and verification completed successfully"
        log "INFO" "Archive verified and ready at: $archive_path"
        log "INFO" "Use --install-to to extract and install files, or --install-pkg for package installation"
    fi
}

# Execute main function with all arguments
main "$@"