#!/usr/bin/env bash

# ==============================================================================
    # r36s_fm.sh
    #
    # File manager for the R36s handheld console.
    #
    # This script analyzes both the filesystem and EmulationStation metadata
    # (gamelist.xml) to identify, validate, classify and organize ROMs together
    # with their related assets and auxiliary files.
    #
    # Author: pleal
    # Project started: 18-10-2025
    # ==============================================================================

    # ==============================================================================
    # TERMINOLOGY
    #
    # system
    #   A console or platform supported by EmulationStation.
    #   Examples: NES, SNES, PSX, Dreamcast.
    #
    # ES (EmulationStation)
    #   Frontend responsible for managing game metadata through gamelist.xml.
    #
    # group
    #   A collection of files sharing the same basename.
    #   Groups represent a single game candidate during the classification process.
    #
    # unclassified
    #   An item that exists either in the filesystem or in gamelist.xml but has
    #   not yet been processed by the classification pipeline.
    #
    # valid
    #   An item that exists in the filesystem and is correctly associated with a
    #   valid game entry in gamelist.xml.
    #
    #   • Games have a matching XML entry.
    #   • Assets belong to a valid game entry.
    #
    # orphan
    #   An item that exists in the filesystem but has no valid parent.
    #
    #   • Games have no corresponding XML entry.
    #   • Assets belong to a ghost game entry.
    #
    # linked
    #   An item without its own XML entry that was successfully associated with a
    #   known game.
    #
    #   • Applies to auxiliary files and filesystem-only assets.
    #   • The associated game may be either valid or orphan.
    #
    # unlinked
    #   An item without its own XML entry that could not be associated with any
    #   known game.
    #
    # ghost
    #   An item referenced by gamelist.xml that does not exist in the filesystem.
    #
    #   • Games are ghost when the ROM is missing.
    #   • Assets are ghost when the referenced asset file is missing.
    #
    #
    # CLASSIFICATION MODEL
    #
    #                 Filesystem                 gamelist.xml
    #                     │                           │
    #                     └──────────────┬────────────┘
    #                                    │
    #                             Classification
    #                                    │
    #                     ┌──────────────┬──────────────┐
    #                     │              │              │
    #                   valid         orphan         ghost
    #                     │              │              │
    #                     │              │              └── Referenced by XML but
    #                     │              │                  missing from filesystem.
    #                     │              │
    #                     │              └── Exists in the filesystem but has
    #                     │                  no valid parent game.
    #                     │
    #                     └── Exists in the filesystem and belongs
    #                         to a valid game entry.
    #
    #   -----------------------------------------------------------------
    #
    #              Files without their own XML entry
    #                           │
    #                    Association
    #                           │
    #                  ┌────────┴────────┐
    #                  │                 │
    #               linked          unlinked
    #                  │                 │
    #                  │                 └── Could not be associated
    #                  │                     with any known game.
    #                  │
    #                  └── Successfully associated with a
    #                      known game (valid or orphan).
    #
    #   -----------------------------------------------------------------
    #
    #   unclassified
    #       Items discovered in either source that have not yet been
    #       processed by the classification pipeline.
# ==============================================================================

# shellcheck disable=SC2059
## shellcheck disable=SC2034

set -u

# ==============================================================================
#  GLOBAL CONSTANTS
# Terminal color output
readonly RED="\033[31m"
readonly GREEN="\033[32m"
readonly YELLOW="\033[33m"
readonly BLUE="\033[34m"
readonly PINK="\033[35m"
readonly CYAN="\033[36m"
readonly ENDCOLOR="\033[0m"
# ==============================================================================

cleanup() {
    if [[ -n "${tmp_game:-}" ]]; then
    echo "Limpando arquivos temporários..."
    rm -f "${tmp_game:-}" "${tmp_output_raw:-}" "${tmp_xsl:-}" "${tmp_output_fmt:-}"
    fi
}
trap cleanup EXIT 2>/dev/null

#####################################################

load_systems_info() {
# Loads the EmulationStation system database and builds lookup tables
# used throughout the classification pipeline.
    local systems_config_file=""
    local system_path="" system_name="" system_dir="" extensions=""
    local extensions_list=()
    local extension=""

    # TODO:
    # Provide a built-in fallback system database when the user's
    # EmulationStation configuration is unavailable.
    systems_config_file="$(sudo find ../. -type f \( -name "es_systems.cfg" -o -name "es_systems.xml" \))"

    # Parse every system defined in the EmulationStation configuration file.
    while IFS='|' read -r system_path system_name extensions; do
        system_dir="${system_path%/*}"
        system_dir="${system_dir##*/}"

        SYSTEM_PATHS["$system_dir"]="$system_path"
        SYSTEM_NAMES["$system_dir"]="$system_name"

        read -ra extensions_list <<< "$extensions"

        # Build lookup tables for fast extension-based queries.
        for extension in "${extensions_list[@]}"; do
            VALID_SYSTEM_EXTENSIONS["$system_dir:$extension"]=1

            if [[ -z "${SYSTEMS_BY_EXTENSION["$extension"]:-}" ]]; then
                VALID_EXTENSIONS["$extension"]=1

                # NOTE:
                # SYSTEMS_BY_EXTENSION IS NOT CURREENTLY USED by the application.
                # Keep it only if future features require reverse extension lookups;
                # otherwise, remove it to avoid unnecessary processing and maintenance.
                SYSTEMS_BY_EXTENSION["$extension"]="$system_dir"

            else
                SYSTEMS_BY_EXTENSION["$extension"]+="|$system_dir"

            fi
        done

    done < <(
        sed 's/&\([^a-zA-Z#]\)/\&amp;\1/g' "$systems_config_file" |
        sudo xmlstarlet sel -t \
            -m "//system" \
            -v "path" -o "|" \
            -v "fullname" -o "|" \
            -v "extension" \
            -n - |
        sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')

    # Pre-escape raw '&' characters that are not part of a valid XML entity.
    # Some EmulationStation configurations contain commands such as "2>&1",
    # which would otherwise cause xmlstarlet to fail while parsing the XML.
}

load_aux_ext_file() {
# Loads the auxiliary file extension database used during classification.

    local script_dir="${BASH_SOURCE%/*}"
    local aux_ext_file="$script_dir/aux_ext.txt"
    local extension="" category="" description=""

    while IFS='|' read -r extension category description; do
        # Skip empty lines and comments.
        [[ -z "$extension" || "$extension" == \#* ]] && continue

        AUX_CATEGORY["$extension"]="$category"
        AUX_DESCRIPTION["$extension"]="$description"

    done < "$aux_ext_file"
}

dir_has_gamelist() {
# Returns success if the directory contains a gamelist.xml file.
    local dir="$1"

    [ -n "$(find "$dir" -type f -name "gamelist.xml" -print -quit)" ] && return 0
    return 1

}


classify_dirs_by_roms() {
# Classifies directories based on whether they contain at least one
# detectable ROM file.

    local -n dirs_list_ref="$1"
    local -n dirs_with_games_ref="$2"
    local -n dirs_without_games_ref="$3"

    dirs_with_games_ref=()
    dirs_without_games_ref=()

    local extension=""
    local find_rom_expression=()
    local dir=""

    # Build the find expression from the list of valid ROM extensions.
    # "-name '*.nes' -o -name '*.chd' -o -name '*.zip'..."
    for extension in "${!VALID_EXTENSIONS[@]}"; do
        if (( ${#find_rom_expression[@]} == 0 )); then
            find_rom_expression+=(-name "*${extension}")
        else
            find_rom_expression+=(-o -name "*${extension}")
        fi
    done

    # TODO:
    # Refine ROM detection for systems whose primary files are project or
    # configuration files (e.g. EasyRPG, ScummVM). Extension-based detection
    # alone may produce false positives.

    for dir in "${dirs_list_ref[@]}"; do
        if dir_has_gamelist "$dir"; then

            # Search for at least one matching ROM file.
            if [ -n "$(find "$dir" -type f \( "${find_rom_expression[@]}" \) -print -quit)" ]; then
                dirs_with_games_ref+=("$dir")
            else
                # TODO:
                # Decide how directories without detectable ROMs should be
                # handled when gamelist.xml is present.
                dirs_without_games_ref+=("$dir")
            fi
        fi
    done
}

is_valid_option() {
# Validates that the user input is numeric and within the valid menu option range.
    local input="$1"
    local max_option="$2"

    if [[ ! "$input" =~ ^[0-9]+$ ]] || [[ "$input" -lt 1 ]] || [[ "$input" -gt "$max_option" ]]; then
        return 1
    fi
    return 0
}

ask_user() {
# Displays an interactive menu and stores the selected option
# in the variable passed by reference.
    local question="${1:-"What would you like to do?"}"
    local -n user_answer_ref="$2"
    shift 2

    local options=( "$@" ) 
    local opt=""

    printf "\n${RED}%s${ENDCOLOR}\n" "$question"
    select opt in "${options[@]}" "Exit"; do
        if [[ "$opt" == "Exit" ]]; then
            echo "Exiting program..."
            exit 0

        # Ignore invalid menu indexes.
        elif is_valid_option "$REPLY" "$#"; then
            user_answer_ref="$opt"
            break
            
        else
            printf "${BLUE}Invalid option! Try again${ENDCOLOR}\n"

        fi               
    done

}

get_all_files() {
# Collect all files from the current directory.
    # ============================================================================
    # Every discovered file is initially considered unclassified. Later pipeline
    # stages progressively move files from this collection into their respective
    # categories.
    # ============================================================================

    shopt -s globstar nullglob

    local -n unclassified_files_ref="$1"

    local file=""

    # Iterate through every file under the current directory
    for file in **/*; do
        if [[ -f "$file" ]];then # Ignore directories and keep only regular files
            unclassified_files_ref["./$file"]=1
            # The associative array is used as a set, where keys are file paths and values are placeholders.
            # Presence of a key indicates that the file has not yet been classified.
        fi
    done

    shopt -u globstar nullglob
}

load_xml_metadata() {
# Loads gamelist.xml metadata and stores exactly as they appear, preserving the relative
# path format (e.g. "./game.zip") used throughout the pipeline.
    local -n xml_unclassified_games_ref="$1"
    local -n unclassified_images_ref="$2"
    local -n unclassified_videos_ref="$3"
    local -n unclassified_marquees_ref="$4"
    local -n unclassified_thumbnails_ref="$5"

    local game_path=""
    local game_name=""

    local image_path=""
    local video_path=""
    local marquee_path=""
    local thumbnail_path=""

    while IFS='|' read -r game_path game_name image_path video_path marquee_path thumbnail_path; do
        # xmlstarlet may emit rows containing empty fields when optional XML elements
        # are missing. So, ignore games without a valid ROM game_path
        [[ -n "$game_path" ]] && xml_unclassified_games_ref["$game_path"]="$game_name"
        
        # Store only existing asset paths to avoid unnecessary empty games.
        [[ -n "$image_path" ]] && unclassified_images_ref["$game_path"]="$image_path"
        [[ -n "$video_path" ]] && unclassified_videos_ref["$game_path"]="$video_path"
        [[ -n "$marquee_path" ]] && unclassified_marquees_ref["$game_path"]="$marquee_path"
        [[ -n "$thumbnail_path" ]] && unclassified_thumbnails_ref["$game_path"]="$thumbnail_path"
        

    done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -o "|" -v "image" \
                -o "|" -v "video" -o "|" -v "marquee" -o "|" -v "thumbnail" -n ./gamelist.xml | \
                sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')
        # Decode XML entities (e.g. $amp) so asset game_paths match the actual filesystem names.
}

classify_xml_games() {
# Match XML games against the discovered files.
    local -n unclassified_files_ref="$1"
    local -n xml_unclassified_games_ref="$2"
    local -n valid_games_ref="$3"
    local -n ghost_games_ref="$4"
    local system="$5"

    local game_path=""
    local game_name=""
    local game_extension=""

    local -A processed_game_names=()

    # Normalize the directory name to match VALID_SYSTEM_EXTENSIONS keys.
    system="${system%%/*}"

    for game_path in "${!xml_unclassified_games_ref[@]}"; do
        game_name="${xml_unclassified_games_ref["$game_path"]}"
        game_extension="${game_path##*.}"

        if [[ -n "${unclassified_files_ref["$game_path"]:-}" ]] &&
           [[ -n "${VALID_SYSTEM_EXTENSIONS["$system:.$game_extension"]:-}" ]]; then


            if [[ -z "${processed_game_names["$game_name"]:-}" ]]; then
            # Entries with an existing file and a valid extension are classified as valid games.
                valid_games_ref["$game_path"]="$game_name"
                processed_game_names["$game_name"]=1

            else
                # When multiple ROMs share the same name, append the file
                # extension to keep their names unique and expose the duplicate.
                valid_games_ref["$game_path"]="$game_name.$game_extension"

            fi
            unset 'unclassified_files_ref[$game_path]'

        else
        # Otherwise, they are treated as ghost games.
            if [[ -z "${processed_game_names["$game_name"]:-}" ]]; then
            # Entries with an existing file and a valid extension are classified as valid games.
                ghost_games_ref["$game_path"]="$game_name"
                processed_game_names["$game_name"]=1

            else
                # When multiple ROMs share the same name, append the file
                # extension to keep their names unique and expose the duplicate.
                ghost_games_ref["$game_path"]="$game_name.$game_extension"

            fi
        fi

        unset 'xml_unclassified_games_ref["$game_path"]'
    done
}

classify_xml_asset() {
# Classify assets referenced by the gamelist.xml.
    # =========================================================================
    # Existing assets are classified according to the validity of their
    # associated game entry. Missing assets are treated as ghost assets.
    # =========================================================================

    local -n unclassified_files_ref="$1"
    local -n unclassified_assets_ref="$2"
    local -n valid_assets_ref="$3"
    local -n orphan_assets_ref="$4"
    local -n ghost_assets_ref="$5"
    local -n valid_games_ref="$6"

    local game_path=""
    local asset_path=""

    for game_path in "${!unclassified_assets_ref[@]}"; do
        asset_path="${unclassified_assets_ref[$game_path]}"

        if [[ -n "${unclassified_files_ref["$asset_path"]:-}" ]]; then

            if [[ -n "${valid_games_ref["$game_path"]:-}" ]]; then
                valid_assets_ref["$game_path"]="$asset_path"

            else 
                orphan_assets_ref["$game_path"]="$asset_path"

            fi

            # The asset file has now been classified.
            unset 'unclassified_files_ref[$asset_path]'

        else
            # The referenced asset does not exist on disk.
            ghost_assets_ref["$game_path"]="$asset_path"
        fi

        # Remove the processed XML reference.
        unset 'unclassified_assets_ref[$game_path]'
    done
}

extract_possible_roms() {
# Identify ROM candidates among the remaining unclassified files.
    # =========================================================================
    # Files are selected solely by their extension. Additional validation is
    # performed in later pipeline stages.
    # =========================================================================

    local -n unclassified_files_ref="$1"
    local -n possible_roms_ref="$2"
    local system="$3"

    local file=""
    local file_extension=""

    # Normalize the directory name to match VALID_SYSTEM_EXTENSIONS keys.
    system="${system%%/*}"

    for file in "${!unclassified_files_ref[@]}"; do
        file_extension="${file##*.}"

        if [[ -n "${VALID_SYSTEM_EXTENSIONS["$system:.$file_extension"]:-}" ]]; then
            possible_roms_ref["$file"]=1
            unset 'unclassified_files_ref[$file]'
        fi
    done
}

group_files() {
# Group files sharing the same base filename.
    # =========================================================================
    # Some games are distributed as multiple files or in different formats.
    # Grouping related files allows later pipeline stages to determine which
    # files belong to the same game.
    #
    # NOTE:
    # This is the only stage where the pipeline temporarily switches from using
    # game_paths as keys to using grouping keys. Each key represents a group of
    # related files, while the value stores the corresponding file paths.
    # =========================================================================

    local -n files_to_group_ref="$1"
    local -n grouped_files_ref="$2"

    local file=""
    local group_key=""

    for file in "${!files_to_group_ref[@]}"; do
        group_key="${file##*/}"
        group_key="${group_key%.*}"

        # Preserve multi-part suffixes such as ".A1.bin" by removing only the
        # final extension before applying this special case.
        [[ "$group_key" == *.A1 ]] && group_key="${group_key%.*}"

        if [[ -z "${grouped_files_ref["$group_key"]:-}" ]]; then
            grouped_files_ref["$group_key"]="$file"
        else
            grouped_files_ref["$group_key"]+="|$file"
        fi
    done
}

classify_possible_roms() {
# Classify ROM candidates that were not referenced by the gamelist.xml.
    # =========================================================================
    # Files are first grouped by their base filename. Each group is then
    # classified either as a configuration file or as an orphan game.
    # =========================================================================

    local -n possible_roms_ref="$1"
    local -n orphan_games_ref="$2"
    local -n unlinked_configs_ref="$3"

    local -A grouped_possible_roms=()
    local group=()
    local group_key=""

    local game_path=""
    local game_extension=""
    local display_name=""

    declare -A blacklist=(
        [konamigx]=1
        [kviper]=1
        [megatech]=1
        [nss]=1
        [playch10]=1
        [skns]=1
        [neogeo]=1
        [Scan_for_nedirs_with_games_ref]=1
    )

    # Group ROM candidates by their base filename.
    group_files possible_roms_ref grouped_possible_roms

    for group_key in "${!grouped_possible_roms[@]}"; do

        if [[ -n "${blacklist[$group_key]:-}" ]]; then
            local config_path="${grouped_possible_roms[$group_key]}"
            unlinked_configs_ref["$config_path"]="$group_key" # group_key=config_name

        else
            IFS='|' read -ra group <<< "${grouped_possible_roms[$group_key]}"

            if (( ${#group[@]} == 1 )); then
                game_path="${group[0]}"
                orphan_games_ref["$game_path"]="$group_key" # group_key=game_name

            else
                # Multiple files in the same group likely represent different
                # versions or formats of the same game. Append the extension to
                # distinguish them in the output.
                for game_path in "${group[@]}"; do
                    game_extension="${game_path##*.}"
                    display_name="$group_key.$game_extension"

                    orphan_games_ref["$game_path"]="$display_name"
                done
            fi
        fi
    done

    # Temporary grouping structures are no longer needed and all the files were classified.
    unset 'grouped_possible_roms'
    unset 'possible_roms_ref'
}

build_game_library() {
# Build the final game library combiniing games referenced by the gamelist.xml
# with orphan games discovered during filesystem analysis 
    local -n valid_games_ref="$1"
    local -n orphan_games_ref="$2"
    local -n game_library_ref="$3"
    
    local game_path=""
    local game_name=""

    for game_path in "${!valid_games_ref[@]}"; do
        game_name="${valid_games_ref[$game_path]}"
        game_library_ref["$game_path"]="$game_name"

    done

    for game_path in "${!orphan_games_ref[@]}"; do
        game_name="${orphan_games_ref[$game_path]}"
        game_library_ref["$game_path"]="$game_name"

    done

}

classify_remaining_files() {
# At this stage, all XML-referenced resources and ROMs have already been
# processed. The remaining files are classified by extension and associated
# with the game library using filename matching.

    local -n unclassified_files_ref="$1"
    local -n game_library_ref="$2"

    local -n linked_images_ref="$3" linked_videos_ref="$4" linked_marquees_ref="$5" linked_thumbnails_ref="$6" linked_auxiliary_ref="$7"
    local -n unlinked_images_ref="$8" unlinked_videos_ref="$9" unlinked_marquees_ref="${10}" unlinked_thumbnails_ref="${11}" unlinked_auxiliary_ref="${12}"
    local -n linked_configs_ref="${13}" unlinked_configs_ref="${14}" unknown_files_ref="${15}"

    local -A grouped_library=()
    local group_key=""

    local file=""
    local file_extension=""
    local game_path=""
    
    local category=""
    local image_suffix=""

    # Group the game library by filename to allow fast association between
    # remaining files and known games.
    group_files game_library_ref grouped_library

    for file in "${!unclassified_files_ref[@]}"; do
        group_key="${file##*/}"
        group_key="${group_key%.*}"

        [[ "$group_key" == *.A1 ]] && group_key="${group_key%.*}"

        file_extension="${file##*.}"

        shopt -s extglob
        # Normalize RetroArch save-state extensions (e.g. ".state1",
        # ".state2") to the generic ".state" category.
        [[ "$file_extension" == state+([0-9]) ]] && file_extension="${file_extension%%+([[:digit:]])}"
        shopt -u extglob

        category="${AUX_CATEGORY["$file_extension"]:-}"

        if [[ -n "${grouped_library["$group_key"]:-}" ]]; then
            game_path="${grouped_library["$group_key"]}"

            case "$category" in
                # ====================================================================
                # Images
                # ====================================================================
                "IMAGE")
                    image_suffix="${group_key##*-}"

                    case "$image_suffix" in
                        "marquee")
                            linked_marquees_ref["$game_path"]="$file"
                            ;;

                        "thumb")
                            linked_thumbnails_ref["$game_path"]="$file"
                            ;;

                        *)
                            linked_images_ref["$game_path"]="$file"
                            ;;
                    esac
                    ;;

                # ====================================================================
                # Videos
                # ====================================================================
                "VIDEO")
                    linked_videos_ref["$game_path"]="$file"
                    ;;

                # ====================================================================
                # Configuration Files
                # Files required by the emulator or system, but not tied to
                # user-generated data.
                # ====================================================================
                "CONFIG" | "FIRMWARE" | "METADATA" | "DATABASE" | "CACHE" | "INDEX" | "SHADER")
                    # TODO: criar func p/ essse tipo de validação
                    if [[ -z "${linked_configs_ref["$game_path"]:-}" ]]; then
                        linked_configs_ref["$game_path"]="$file"
                    else
                        linked_configs_ref["$game_path"]+="|$file"
                    fi
                    ;;

                # ====================================================================
                # Auxiliary Files
                # Files associated with the game or the user.
                # ====================================================================
                "SAVE" | "SAVE_STATE" | "HIGH_SCORE" | "DIFF" | "CHEAT" | "REPLAY" | "PATCH" | \
                "DISC_DESCRIPTOR" | "DISC_METADATA" | "PLAYLIST" | "AUDIO" | "ARTWORK" | \
                "FONT" | "DOCUMENT" | "LOG" | "BACKUP")
                    if [[ -z "${linked_auxiliary_ref["$game_path"]:-}" ]]; then
                        linked_auxiliary_ref["$game_path"]="$file"
                    else
                        linked_auxiliary_ref["$game_path"]+="|$file"
                    fi
                    ;;

                # ====================================================================
                # Unknown
                # ====================================================================
                *)
                    unknown_files_ref["$game_path"]="$file"
                    ;;
            esac

        else
            case "$category" in
                # ====================================================================
                # Images
                # ====================================================================
                "IMAGE")
                    image_suffix="${group_key##*-}"

                    case "$image_suffix" in
                        "marquee")
                            unlinked_marquees_ref["$file"]="$group_key"
                            ;;

                        "thumb")
                            unlinked_thumbnails_ref["$file"]="$group_key"
                            ;;

                        *)
                            unlinked_images_ref["$file"]="$group_key"
                            ;;
                    esac
                    ;;

                # ====================================================================
                # Videos
                # ====================================================================
                "VIDEO")
                    unlinked_videos_ref["$file"]="$group_key"
                    ;;

                # ====================================================================
                # Configuration Files
                # ====================================================================
                "CONFIG" | "FIRMWARE" | "METADATA" | "DATABASE" | "CACHE" | "INDEX" | "SHADER")
                    unlinked_configs_ref["$file"]="$group_key"
                    ;;

                # ====================================================================
                # Auxiliary Files
                # ====================================================================
                "SAVE" | "SAVE_STATE" | "HIGH_SCORE" | "DIFF" | "CHEAT" | "REPLAY" | "PATCH" | \
                "DISC_DESCRIPTOR" | "DISC_METADATA" | "PLAYLIST" | "AUDIO" | "ARTWORK" | \
                "FONT" | "DOCUMENT" | "LOG" | "BACKUP")
                    unlinked_auxiliary_ref["$file"]="$group_key"
                    ;;

                # ====================================================================
                # Unknown
                # ====================================================================
                *)
                    unknown_files_ref["$file"]="$group_key"
                    ;;
            esac
        fi

        unset 'unclassified_files_ref[$file]'
    done
}

reset_analysis_state() {
# Resets all analysis arrays before running the directory pipeline.
    # File discovery.
    unclassified_files=()
    xml_unclassified_games=()

    # Game classification.
    valid_games=()
    ghost_games=()
    orphan_games=()
    game_library=()

    # XML asset classification.
    unclassified_images=()
    unclassified_videos=()
    unclassified_marquees=()
    unclassified_thumbnails=()

    valid_images=()
    valid_videos=()
    valid_marquees=()
    valid_thumbnails=()

    orphan_images=()
    orphan_videos=()
    orphan_marquees=()
    orphan_thumbnails=()

    ghost_images=()
    ghost_videos=()
    ghost_marquees=()
    ghost_thumbnails=()

    # Filesystem asset classification.
    linked_images=()
    linked_videos=()
    linked_marquees=()
    linked_thumbnails=()

    unlinked_images=()
    unlinked_videos=()
    unlinked_marquees=()
    unlinked_thumbnails=()

    # Auxiliary and configuration files.
    linked_auxiliary=()
    unlinked_auxiliary=()

    linked_configs=()
    unlinked_configs=()

    # Uncategorized files.
    unknown_files=()
}

analyze_directory() {
# Executes the complete directory analysis pipeline.
    local system_dir="$1"

    # Collect all files from the selected directory.
    get_all_files unclassified_files

    # Load and classify files referenced by gamelist.xml.
    load_xml_metadata \
        xml_unclassified_games \
        unclassified_images \
        unclassified_videos \
        unclassified_marquees \
        unclassified_thumbnails

    classify_xml_games \
        unclassified_files \
        xml_unclassified_games \
        valid_games \
        ghost_games \
        "$system_dir"

    # Classify assets referenced by gamelist.xml.
    local assets_names=( "images" "videos" "marquees" "thumbnails" )
    local name=""

    for name in "${assets_names[@]}"; do
        local -n arr_ref="unclassified_${name}"

        # Skip empty asset collections.
        (( ${#arr_ref[@]} == 0 )) && continue

        classify_xml_asset \
            unclassified_files \
            "unclassified_${name}" \
            "valid_${name}" \
            "orphan_${name}" \
            "ghost_${name}" \
            valid_games
    done

    # Identify and classify ROM files.
    local -A possible_roms=()

    extract_possible_roms \
        unclassified_files \
        possible_roms \
        "$system_dir"
        
    if (( ${#possible_roms[@]} > 0 )); then
        classify_possible_roms \
            possible_roms \
            orphan_games \
            unlinked_configs
    fi

    # Build the complete game library.
    build_game_library \
        valid_games \
        orphan_games \
        game_library


    # Classify all remaining files.
    classify_remaining_files \
        unclassified_files \
        game_library \
        linked_images linked_videos linked_marquees linked_thumbnails linked_auxiliary \
        unlinked_images unlinked_videos unlinked_marquees unlinked_thumbnails unlinked_auxiliary \
        linked_configs unlinked_configs unknown_files
}

print_summary_line() {
    local label="$1"
    local value="$2"
    local color="${3:-}"

    [[ "$value" =~ ^[0-9]+$ ]] && (( "$value" == 0 )) && return 202

    printf " %-30s " "${label}:"

    [[ -n "$color" ]] && printf "%b" "$color"
    printf "%6s" "$value"
    [[ -n "$color" ]] && printf "%b" "$ENDCOLOR"

    printf "\n"
}

print_directory_summary() {
# Displays a summary of the current directory analysis.
    local system_dir="$1"
    system_dir="${system_dir%/}"

    printf "\n${PINK}============================================================${ENDCOLOR}\n"
    printf "${PINK}                 %s SUMMARY${ENDCOLOR}\n" "${SYSTEM_NAMES["$system_dir"]:-}"
    printf "${PINK}============================================================${ENDCOLOR}\n"

    printf "\n${YELLOW}────────────── Games ──────────────${ENDCOLOR}\n"

    print_summary_line "Library Size"      "${#game_library[@]}"
    print_summary_line "XML Games"         "${#valid_games[@]}"

    local color=""

    color=""
    (( ${#orphan_games[@]} > 0 )) && color="$YELLOW"
    print_summary_line "Orphan Games" "${#orphan_games[@]}" "$color"

    color=""
    (( ${#ghost_games[@]} > 0 )) && color="$RED"
    print_summary_line "Ghost Games" "${#ghost_games[@]}" "$color"

    printf "\n${YELLOW}────────────── Assets ─────────────${ENDCOLOR}\n"

    print_summary_line "Valid Images"       "${#valid_images[@]}"
    print_summary_line "Valid Videos"       "${#valid_videos[@]}"
    print_summary_line "Valid Marquees"     "${#valid_marquees[@]}"
    print_summary_line "Valid Thumbnails"   "${#valid_thumbnails[@]}"
    
    (( ${#valid_images[@]} > 0 )) || (( ${#valid_videos[@]} > 0 )) || \
    (( ${#valid_marquees[@]} > 0 )) || (( ${#valid_thumbnails[@]} > 0 )) && \
    echo ""

    print_summary_line "Orphan Images"       "${#orphan_images[@]}"
    print_summary_line "Orphan Videos"       "${#orphan_videos[@]}"
    print_summary_line "Orphan Marquees"     "${#orphan_marquees[@]}"
    print_summary_line "Orphan Thumbnails"   "${#orphan_thumbnails[@]}"
     
    (( ${#orphan_images[@]} > 0 )) || (( ${#orphan_videos[@]} > 0 )) || \
    (( ${#orphan_marquees[@]} > 0 )) || (( ${#orphan_thumbnails[@]} > 0 )) && \
    echo ""

    print_summary_line "Ghost Images"       "${#ghost_images[@]}"
    print_summary_line "Ghost Videos"       "${#ghost_videos[@]}"
    print_summary_line "Ghost Marquees"     "${#ghost_marquees[@]}"
    print_summary_line "Ghost Thumbnails"   "${#ghost_thumbnails[@]}"
     
    (( ${#ghost_images[@]} > 0 )) || (( ${#ghost_videos[@]} > 0 )) || \
    (( ${#ghost_marquees[@]} > 0 )) || (( ${#ghost_thumbnails[@]} > 0 )) && \
    echo ""

    print_summary_line "Linked Images"       "${#linked_images[@]}"
    print_summary_line "Linked Videos"       "${#linked_videos[@]}"
    print_summary_line "Linked Marquees"     "${#linked_marquees[@]}"
    print_summary_line "Linked Thumbnails"   "${#linked_thumbnails[@]}"
     
    (( ${#linked_images[@]} > 0 )) || (( ${#linked_videos[@]} > 0 )) || \
    (( ${#linked_marquees[@]} > 0 )) || (( ${#linked_thumbnails[@]} > 0 )) && \
    echo ""

    print_summary_line "Unlinked Images"     "${#unlinked_images[@]}"
    print_summary_line "Unlinked Videos"     "${#unlinked_videos[@]}"
    print_summary_line "Unlinked Marquees"   "${#unlinked_marquees[@]}"
    print_summary_line "Unlinked Thumbnails" "${#unlinked_thumbnails[@]}"

    printf "\n${YELLOW}────────── Support Files ──────────${ENDCOLOR}\n"

    print_summary_line "Linked Auxiliary"    "${#linked_auxiliary[@]}"
    print_summary_line "Unlinked Auxiliary"  "${#unlinked_auxiliary[@]}"
     
    (( ${#linked_auxiliary[@]} > 0 )) || (( ${#unlinked_auxiliary[@]} > 0 )) && \
    echo ""

    print_summary_line "Linked Config"       "${#linked_configs[@]}"
    print_summary_line "Unlinked Config"     "${#unlinked_configs[@]}"

    printf "\n${YELLOW}────────────── Other ──────────────${ENDCOLOR}\n"

    print_summary_line "Unknown Files" "${#unknown_files[@]}"

    printf "\n${PINK}============================================================${ENDCOLOR}\n"
}

count_by_dir() {
# GAMBIARRA P/ DEEBUG - IMMPLEMENTAR CORRETAMENTE DEPOIS!!!
    local -n dirs_with_games_ref="$1"

    local dir=""
    local -i total_games=0

    for dir in "${dirs_with_games_ref[@]}"; do
        cd -- "$dir" || exit 1

        unclassified_files=()
        xml_unclassified_games=()
        valid_games=()
        ghost_games=() 
        orphan_games=()
        game_library=()

        local -A unclassified_images=() unclassified_videos=() unclassified_marquees=() unclassified_thumbnails=()
        local -A valid_images=() valid_videos=() valid_marquees=() valid_thumbnails=()
        local -A unlinked_images=() unlinked_videos=() unlinked_marquees=() unlinked_thumbnails=()
        local -A ghost_images=() ghost_videos=() ghost_marquees=() ghost_thumbnails=()

        get_all_files unclassified_files 
        
        load_xml_metadata xml_unclassified_games unclassified_images unclassified_videos unclassified_marquees unclassified_thumbnails

        classify_xml_games unclassified_files xml_unclassified_games valid_games ghost_games "$dir"

        local assets_names=( "images" "videos" "marquees" "thumbnails" )
        local name=""
        # certeza q tem forma de abstrair classify_xml_asset() p/ q lide com todos os assets de uma vez, mas por enquanto isso serve
        for name in "${assets_names[@]}"; do
            local -n arr_ref="unclassified_${name}"
            # printf "Tamanho de %s: %d\n" "${!arr_ref}" "${#arr_ref[@]}"
            # se ñ há assets p/ serem classificados, ñ há necessidade de classificar oq não existe
            (( ${#arr_ref[@]} > 0 )) && classify_xml_asset unclassified_files "unclassified_${name}" "valid_${name}" "orphan_${name}" "ghost_${name}" valid_games
        done

        local -A possible_roms=() grouped_possible_roms=() grouped_valid_games=() config_files=()
        
        extract_possible_roms unclassified_files possible_roms "$dir"
        group_files possible_roms grouped_possible_roms
        classify_possible_roms grouped_possible_roms orphan_games config_files
        build_game_library valid_games orphan_games game_library

        total_games+="${#game_library[@]}"

        printf "\n========== ${GREEN}%s${ENDCOLOR} ==========\n" "$dir"
        printf "XML válidos      : %d\n" "${#valid_games[@]}"
        printf "Jogos órfãos     : %d\n" "${#orphan_games[@]}"
        printf "Jogos fantasma: %d\n" "${#ghost_games[@]}"
        printf "${CYAN}Total de jogos   : %d${ENDCOLOR}\n" "${#game_library[@]}"
        printf "${RED}Não classificados   : %d${ENDCOLOR}\n" "${#unclassified_files[@]}"
        printf "===========================\n\n"
        
        # for file in "${!unclassified_files[@]}"; do
        #     printf "File: ${PINK}%s${ENDCOLOR}\n" "$file"
        
        # done 
    
        cd "$OLDPWD" || exit 1
    done

    printf "Total de jogos   : %d\n" "$total_games"
}

sort_games() {
# Orndena os jogos alfabeticamente
    local -n sorted="$1"
    shift 1
    mapfile -t sorted < <( printf "%s\n" "$@" | sort -f )
}

build_target_collection() {
# Inverte um array associativo de jogos (path -> name)
# para um array (name -> path), usado pelos menus seguintes.
    local -n source_ref="$1"
    local -n target_ref="$2"

    local game_path
    local game_name

    target_ref=()

    for game_path in "${!source_ref[@]}"; do
        game_name="${source_ref["$game_path"]}"
        target_ref["$game_name"]="$game_path"
    done

}

load_game_context() {
# Loads all information related to the selected game into the context.
    local -n game_context_ref="$1"
    local game_path="$2"
    local game_name="$3"

    game_context_ref=()
    game_context_ref["path"]="$game_path"
    game_context_ref["name"]="$game_name"

    if [[ -n "${valid_games["$game_path"]:-}" ]]; then
        game_context_ref["status"]="Valid"

    elif [[ -n "${orphan_games["$game_path"]:-}" ]]; then
        game_context_ref["status"]="Orphan"

    else
        game_context_ref["status"]="Ghost"

    fi

    if [[ "${game_context_ref["status"]}" != "Orphan" ]]; then
        local safe_xpath
        safe_xpath=$(escape_xpath_string "$game_path")

        game_context_ref["xml_node"]="$(
            xmlstarlet sel \
                -t -c "//game[path=$safe_xpath]" \
                "./gamelist.xml"
        )"
    fi

    [[ -n "${valid_images["$game_path"]:-}"      ]] && \
        game_context_ref["valid_image"]="${valid_images["$game_path"]}" && \
            (( game_context_ref["valid_asset_count"]+=1 ))

    [[ -n "${valid_videos["$game_path"]:-}"      ]] && \
        game_context_ref["valid_video"]="${valid_videos["$game_path"]}" && \
            (( game_context_ref["valid_asset_count"]+=1 ))

    [[ -n "${valid_marquees["$game_path"]:-}"    ]] && \
        game_context_ref["valid_marquee"]="${valid_marquees["$game_path"]}" && \
            (( game_context_ref["valid_asset_count"]+=1 ))

    [[ -n "${valid_thumbnails["$game_path"]:-}"  ]] && \
        game_context_ref["valid_thumbnail"]="${valid_thumbnails["$game_path"]}" && \
            (( game_context_ref["valid_asset_count"]+=1 ))


    [[ -n "${orphan_images["$game_path"]:-}"     ]] && \
        game_context_ref["orphan_image"]="${orphan_images["$game_path"]}" && \
            (( game_context_ref["orphan_asset_count"]+=1 ))

    [[ -n "${orphan_videos["$game_path"]:-}"     ]] && \
        game_context_ref["orphan_video"]="${orphan_videos["$game_path"]}" && \
            (( game_context_ref["orphan_asset_count"]+=1 ))

    [[ -n "${orphan_marquees["$game_path"]:-}"   ]] && \
        game_context_ref["orphan_marquee"]="${orphan_marquees["$game_path"]}" && \
            (( game_context_ref["orphan_asset_count"]+=1 ))

    [[ -n "${orphan_thumbnails["$game_path"]:-}" ]] && \
        game_context_ref["orphan_thumbnail"]="${orphan_thumbnails["$game_path"]}" && \
            (( game_context_ref["orphan_asset_count"]+=1 ))


    [[ -n "${ghost_images["$game_path"]:-}"      ]] && \
        game_context_ref["ghost_image"]="${ghost_images["$game_path"]}" && \
            (( game_context_ref["ghost_asset_count"]+=1 ))

    [[ -n "${ghost_videos["$game_path"]:-}"      ]] && \
        game_context_ref["ghost_video"]="${ghost_videos["$game_path"]}" && \
            (( game_context_ref["ghost_asset_count"]+=1 ))

    [[ -n "${ghost_marquees["$game_path"]:-}"    ]] && \
        game_context_ref["ghost_marquee"]="${ghost_marquees["$game_path"]}" && \
            (( game_context_ref["ghost_asset_count"]+=1 ))

    [[ -n "${ghost_thumbnails["$game_path"]:-}"  ]] && \
        game_context_ref["ghost_thumbnail"]="${ghost_thumbnails["$game_path"]}" && \
            (( game_context_ref["ghost_asset_count"]+=1 ))


    [[ -n "${linked_images["$game_path"]:-}"     ]] && \
        game_context_ref["linked_image"]="${linked_images["$game_path"]}" && \
            (( game_context_ref["linked_asset_count"]+=1 ))

    [[ -n "${linked_videos["$game_path"]:-}"     ]] && \
        game_context_ref["linked_video"]="${linked_videos["$game_path"]}" && \
            (( game_context_ref["linked_asset_count"]+=1 ))

    [[ -n "${linked_marquees["$game_path"]:-}"   ]] && \
        game_context_ref["linked_marquee"]="${linked_marquees["$game_path"]}" && \
            (( game_context_ref["linked_asset_count"]+=1 ))

    [[ -n "${linked_thumbnails["$game_path"]:-}" ]] && \
        game_context_ref["linked_thumbnail"]="${linked_thumbnails["$game_path"]}" && \
            (( game_context_ref["linked_asset_count"]+=1 ))


    [[ -n "${linked_auxiliary["$game_path"]:-}"  ]] && \
        game_context_ref["linked_auxiliary"]="${linked_auxiliary["$game_path"]}" && \
            (( game_context_ref["linked_support_count"]+=1 ))

    [[ -n "${linked_configs["$game_path"]:-}"    ]] && \
        game_context_ref["linked_configs"]="${linked_configs["$game_path"]}" && \
            (( game_context_ref["linked_support_count"]+=1 ))

}

context_status_icon() {
# Returns a colored checkmark or cross depending on whether the key exists.

    local -n ctx_ref="$1"
    local key="$2"

    if [[ -n "${ctx_ref[$key]:-}" ]]; then
        printf "${GREEN}✓${ENDCOLOR}"
    else
        printf "${RED}✗${ENDCOLOR}"
    fi
}

print_game_context() {
# Displays a summary of the selected game.

    local -n context_ref="$1"

    printf "\n${PINK}============================================================${ENDCOLOR}\n"
    printf "                    %s Data\n" "${context_ref[name]}"
    printf "${PINK}============================================================${ENDCOLOR}\n\n"

    printf " Status: %s\n" "${context_ref[status]}"

    printf "\n${YELLOW}──────────────Valid Assets ─────────────${ENDCOLOR}\n"
    print_summary_line "Image"     "$(context_status_icon context_ref valid_image)"
    print_summary_line "Video"     "$(context_status_icon context_ref valid_video)"
    print_summary_line "Marquee"   "$(context_status_icon context_ref valid_marquee)"
    print_summary_line "Thumbnail" "$(context_status_icon context_ref valid_thumbnail)"


    printf "\n${YELLOW}────────────── Orphan Assets ─────────────${ENDCOLOR}\n"
    print_summary_line "Image"     "$(context_status_icon context_ref orphan_image)"
    print_summary_line "Video"     "$(context_status_icon context_ref orphan_video)"
    print_summary_line "Marquee"   "$(context_status_icon context_ref orphan_marquee)"
    print_summary_line "Thumbnail" "$(context_status_icon context_ref orphan_thumbnail)"


    printf "\n${YELLOW}──────────────Ghost Assets ─────────────${ENDCOLOR}\n"
    print_summary_line "Image"     "$(context_status_icon context_ref ghost_image)"
    print_summary_line "Video"     "$(context_status_icon context_ref ghost_video)"
    print_summary_line "Marquee"   "$(context_status_icon context_ref ghost_marquee)"
    print_summary_line "Thumbnail" "$(context_status_icon context_ref ghost_thumbnail)"


    printf "\n${YELLOW}────────────── Linked Files ─────────────${ENDCOLOR}\n"
    print_summary_line "Image"      "$(context_status_icon context_ref linked_image)"
    print_summary_line "Video"      "$(context_status_icon context_ref linked_video)"
    print_summary_line "Marquee"    "$(context_status_icon context_ref linked_marquee)"
    print_summary_line "Thumbnail"  "$(context_status_icon context_ref linked_thumbnail)"
    print_summary_line "Auxiliary"  "$(context_status_icon context_ref linked_auxiliary)"
    print_summary_line "Config"     "$(context_status_icon context_ref linked_configs)"


    
    printf "\n${PINK}============================================================${ENDCOLOR}\n"
}

create_gamelist() {
# Creates a minimal gamelist.xml at the specified path.
    local target="$1"
    printf "Creating ${GREEN}%s${ENDCOLOR}\n" "$target"

    if sudo tee "$target" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<gameList>
</gameList>
EOF
    then
        printf "${GREEN}gamelist.xml created successfully.${ENDCOLOR}\n"
        return 0
    else
        printf "${RED}Failed to create gamelist.xml.${ENDCOLOR}\n"
        return 1
    fi
}

escape_xpath_string() {
# Se não escapar corretamente, jogos como NFL' 95 quebram o XPath
    local s="$1"
    if [[ "$s" == *"'"* ]]; then
        # Divide por aspas simples e concatena
        local parts=()
        IFS="'" read -ra chunks <<< "$s"
        for i in "${!chunks[@]}"; do
            parts+=("'${chunks[$i]}'")
            # Insere o caractere de aspas entre partes (menos depois da última)
            if [[ $i -lt $((${#chunks[@]} - 1)) ]]; then
                parts+=("\"'\"")
            fi
        done
        printf "concat(%s)" "$(IFS=','; echo "${parts[*]}")"
    else
        printf "'%s'" "$s"
    fi
}

duplicate_gamelist_with_entry() {
# Creates a validated temporary copy of the target gamelist.xml with a new
# <game> node appended. The original gamelist is never modified by this function.
    local node="$1"
    local target_gamelist="$2"

    local -n tmp_output_fmt="$3"

    local open_text_editor="${4:-false}" # flag q controla a edição de metadados
    
     printf "Creating temporary files...\n"

    # Temporary files used during XML generation.
    local tmp_game
    local tmp_xsl
    local tmp_output_raw
    
    tmp_game="$(mktemp --tmpdir game.XXXXXX.xml)" || return 1
    printf "%s ---> ${GREEN}Success!${ENDCOLOR}\n" "$tmp_game"

    tmp_xsl="$(mktemp --tmpdir append.XXXXXX.xsl)" || return 1
    printf "%s ---> ${GREEN}Success!${ENDCOLOR}\n" "$tmp_xsl"

    tmp_output_raw="$(mktemp --tmpdir out_raw.XXXXXX.xml)" || return 1
    printf "%s ---> ${GREEN}Success!${ENDCOLOR}\n" "$tmp_output_raw"

    tmp_output_fmt="$(mktemp --tmpdir out_fmt.XXXXXX.xml)" || return 1
    printf "%s ---> ${GREEN}Success!${ENDCOLOR}\n" "$tmp_output_fmt"

    # -------------------------------------------------------------------------
    # Step 1 - Persist the XML node into a temporary document.
    #
    # xsltproc imports external XML documents through document(), therefore the
    # node is temporarily written to disk before applying the stylesheet.
    # -------------------------------------------------------------------------

    printf "Preparing game entry...\n"

    printf '%s\n' "$node" > "$tmp_game" || return 1


    if "$open_text_editor"; then
        code --wait "$tmp_game"
    fi

    # -------------------------------------------------------------------------
    # Step 2 - Create the stylesheet responsible for appending the game node to
    #          the destination gamelist.
    #
    # WARNING:
    # Do not indent the heredoc delimiter. Doing so will produce an invalid
    # stylesheet and may generate an invalid output XML.
    # -------------------------------------------------------------------------
    printf "Creating temporary gamelist copy...\n"

    cat > "$tmp_xsl" <<XSL
<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">

  <xsl:output method="xml" indent="no"/>

  <!-- Identity transform: copy every node unchanged -->
  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

  <!-- Append the imported <game> node before closing </gameList> -->
  <xsl:template match="gameList">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
      <xsl:apply-templates select="document('$tmp_game')/game"/>
    </xsl:copy>
  </xsl:template>

</xsl:stylesheet>
XSL
    # -------------------------------------------------------------------------
    # Step 3 - Apply the stylesheet to generate the merged XML.
    # -------------------------------------------------------------------------
    xsltproc "$tmp_xsl" "$target_gamelist" > "$tmp_output_raw" || return 1

    # -------------------------------------------------------------------------
    # Step 4 - Normalize the XML formatting.
    # -------------------------------------------------------------------------
    xmlstarlet fo -t --encode utf-8 \
        "$tmp_output_raw" > "$tmp_output_fmt" || return 1

    # -------------------------------------------------------------------------
    # Step 5 - Validate the generated XML before replacing the original file.
    # -------------------------------------------------------------------------
    if ! xmlstarlet val -q "$tmp_output_fmt"; then
        printf "${BLUE}Error: Temporary XML is invalid. Operation cancelled.${ENDCOLOR}\n"
        return 1
    fi

    # The validated temporary XML is now ready to replace the original gamelist.
    return 0
    
}

replace_gamelist() {
# Replaces the destination gamelist.xml with the updated temporary file.
    local target_gamelist="$1"
    local new_gamelist="$2"

    if sudo mv "$new_gamelist" "$target_gamelist" 2>/dev/null; then
        return 0
    else
        printf "${BLUE}Failed to replace the destination gamelist.xml. Check file permissions.${ENDCOLOR}\n"
        return 1
    fi
}

rm_gamelist_entry() {
# Removes the first matching game entry from the source gamelist.xml.
    local game_path="$1"
    
    local safe_xpath
    
    printf "${CYAN}Removing node from the source gamelist...${ENDCOLOR}\n"
    
    safe_xpath=$(escape_xpath_string "$game_path")    

    if sudo xmlstarlet ed --inplace -d "(//game[path=$safe_xpath])[1]" "./gamelist.xml"; then
        return 0
    else
        printf "${BLUE}Failed to remove the node from the source gamelist. Check permissions and/or file integrity.${ENDCOLOR}\n"
        return 1
    fi
}

transfer_gamelist_entry() {
# Transfers a game entry from the source gamelist.xml to the target gamelist.xml.
    # =========================================================================
    # Pipeline:
    #   1. Create and validate a temporary copy of the target gamelist.xml
    #      containing the new entry.
    #   2. Replace the target gamelist.xml with the validated temporary file.
    #   3. Remove the transferred entry from the source gamelist.xml.
    #
    # The source entry is only removed after the target gamelist.xml has been
    # successfully updated, preventing metadata loss if any previous step fails.
    # =========================================================================
    local -n game_ctx_ref="$1"
    local -n target_dir_ctx_ref="$2"
    local remove_from_source="${3:-true}"

    local tmp_gamelist=""

    if ! duplicate_gamelist_with_entry \
        "${game_ctx_ref["xml_node"]}" \
        "${target_dir_ctx_ref["gamelist"]}" \
        tmp_gamelist; then
        return 1
    fi

    printf "${GREEN}Temporary gamelist.xml created and validated successfully!${ENDCOLOR}\n"

    if ! replace_gamelist \
        "${target_dir_ctx_ref["gamelist"]}" \
        "$tmp_gamelist"; then
        return 1
    fi

    printf "${YELLOW}Target gamelist.xml updated successfully!${ENDCOLOR}\n"

    if "$remove_from_source"; then
        if ! rm_gamelist_entry "${game_ctx_ref["path"]}"; then
            return 1
        fi
        printf "${YELLOW}Source gamelist.xml entry removed successfully!${ENDCOLOR}\n"
    
    fi

    return 0
}

prepare_target_directory() {
# Prompts the user for a destination directory and prepares it for file operations.
    local -n target_dir_context_ref="$1"

    local answer=""

    while true; do
    # Always returns a valid existing directory in target_dir_context["dir"].
        read -r -p "Enter target directory: " target_dir_context_ref["dir"]

        if [[ ! -d "${target_dir_context_ref["dir"]}" ]]; then
            printf "${BLUE}Directory not found. Try again.${ENDCOLOR}\n"
            continue
        fi

        printf "${GREEN}Directory validated.${ENDCOLOR}\n"
        break
    done

    if [[ -f "${target_dir_context_ref["dir"]}/gamelist.xml" ]]; then
    # target_dir_context["gamelist"] is only set if a gamelist.xml exists
    # or the user chooses to create one.
        printf "${GREEN}gamelist.xml found.${ENDCOLOR}\n"
        target_dir_context_ref["gamelist"]="${target_dir_context_ref["dir"]}/gamelist.xml"

    else
        printf "${CYAN}gamelist.xml not found.${ENDCOLOR}\n"

        while true; do
        # The user decides whether a new gamelist.xml should be created.
        # This function intentionally does not force its creation.
            read -r -p "Create gamelist.xml? (y/n) -> " answer

            case "$answer" in
                [Yy])
                    create_gamelist "${target_dir_context_ref["dir"]}/gamelist.xml" && \
                    target_dir_context_ref["gamelist"]="${target_dir_context_ref["dir"]}/gamelist.xml"
                    break
                ;;

                [Nn])
                    # Leave the context without a "gamelist" key.
                    # The caller is responsible for handling this case.
                    break
                ;;

                *)
                    printf "${BLUE}Invalid option. Try again.${ENDCOLOR}\n"
                ;;
            esac
        done
    fi
}

process_related_files() {
# Processes all files associated with a game (assets, saves, configs, etc.).
    # The game itself is handled separately by mv_game() because it is the pivot
    # of the operation. Failures while processing related files are reported, but
    # do not interrupt the remaining files.

    local -n game_ctx_ref="$1"
    local command="$2"
    local target_dir="${3:-}"

    local key=""
    local file=""
    local sub_dir=""
    local target_sub_dir=""
    local answer=""

    for key in "${!game_ctx_ref[@]}"; do
        # Skip context metadata and ghost assets.
        # Only entries representing existing related files are processed.
        if [[ "$key" != "name" ]] &&
           [[ "$key" != "path" ]] &&
           [[ "$key" != "status" ]] &&
           [[ "$key" != "xml_node" ]] &&
           [[ "$key" != *_count ]] &&
           [[ "$key" != ghost_* ]]; then

            file="${game_ctx_ref["$key"]}"

            printf "Processing ${PINK}%s${ENDCOLOR}\n" "$file"

            # Removing files does not require a destination.
            # Skip all target directory handling and execute the command directly.
            if [[ "$command" != "rm" ]]; then

                # Preserve the original directory structure whenever possible.
                # Example:
                #   ./images/game.png -> target/images/
                #   ./saves/game.srm  -> target/saves/
                sub_dir="${file%/*}"
                sub_dir="${sub_dir#./}"

                if [[ "$sub_dir" =~ ^\. ]]; then
                    target_sub_dir="$target_dir"
                else
                    target_sub_dir="$target_dir/$sub_dir"
                fi

                if [[ ! -d "$target_sub_dir" ]]; then
                    printf "${BLUE}%s doesn't exist${ENDCOLOR}\n" "$target_sub_dir"
                    printf "${RED}Create %s? (y/n) ${ENDCOLOR}" "$target_sub_dir"

                    while true; do
                        read -r -p "-> " answer

                        case "$answer" in
                            [Yy])
                                if sudo mkdir -p "$target_sub_dir"; then
                                    printf "${GREEN}%s created${ENDCOLOR}\n" "$target_sub_dir"
                                    break
                                fi

                                printf "${RED}Failed to create %s.${ENDCOLOR}\n" "$target_sub_dir"

                                # If the directory cannot be created, allow the
                                # user to either place the files directly in the
                                # target directory or skip this group entirely.
                                while true; do
                                    printf "${RED}Process these files in the main target directory instead? (y/n) ${ENDCOLOR}"
                                    read -r -p "-> " answer

                                    case "$answer" in
                                        [Yy])
                                            target_sub_dir="$target_dir"
                                            break 2
                                            ;;

                                        [Nn])
                                            printf "${YELLOW}Skipping files from %s.${ENDCOLOR}\n" "$sub_dir"
                                            continue 2
                                            ;;

                                        *)
                                            printf "${BLUE}Invalid option. Try again.${ENDCOLOR}\n"
                                            ;;
                                    esac
                                done
                                ;;

                            [Nn])
                                # User chose not to recreate the directory.
                                # Store the files directly in the destination root.
                                target_sub_dir="$target_dir"
                                break
                                ;;

                            *)
                                printf "${BLUE}Invalid option. Try again.${ENDCOLOR}\n"
                                ;;
                        esac
                    done
                fi
            fi

            case "$command" in
                "mv")
                    printf "Moving ${GREEN}%s${ENDCOLOR} to ${GREEN}%s${ENDCOLOR}\n" \
                        "$file" "$target_sub_dir"

                    if sudo mv "$file" "$target_sub_dir"; then
                        printf "${GREEN}File moved successfully!${ENDCOLOR}\n\n"
                    else
                        printf "${RED}Failed to move %s.${ENDCOLOR}\n\n" "$file"
                    fi
                    ;;

                "cp")
                    printf "Copying ${GREEN}%s${ENDCOLOR} to ${GREEN}%s${ENDCOLOR}\n" \
                        "$file" "$target_sub_dir"

                    if sudo cp "$file" "$target_sub_dir"; then
                        printf "${GREEN}File copied successfully!${ENDCOLOR}\n\n"
                    else
                        printf "${RED}Failed to copy %s.${ENDCOLOR}\n\n" "$file"
                    fi
                    ;;

                "rm")
                    printf "Removing ${GREEN}%s${ENDCOLOR}\n" "$file"

                    if sudo rm "$file"; then
                        printf "${GREEN}File removed successfully!${ENDCOLOR}\n\n"
                    else
                        printf "${RED}Failed to remove %s.${ENDCOLOR}\n\n" "$file"
                    fi
                    ;;
            esac
        fi
    done
}

mv_game() {
    local -n game_context_ref="$1"
    local -n target_dir_context_ref="$2"

    local answer=""

    printf "Moving ${GREEN}%s${ENDCOLOR} to ${GREEN}%s${ENDCOLOR}\n" \
    "${game_context_ref["name"]}" \
    "${target_dir_context_ref["dir"]}"

    if sudo mv "${game_context_ref["path"]}" "${target_dir_context_ref["dir"]}"; then
        printf "${YELLOW}Game moved successfully!${ENDCOLOR}\n"
    else
        printf "${BLUE}Failed to move game!${ENDCOLOR}\n"
        return 1
    fi
    
    if [[ -n "${game_context_ref["valid_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["orphan_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["linked_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["linked_support_count"]:-}" ]]; then

        printf "${RED}Do you want to move all related files too? (y/n) ${ENDCOLOR}"
        while true; do
            read -r -p "-> " answer
            echo ""

            case "$answer" in
                [Yy])
                    process_related_files game_context_ref "mv" "${target_dir_context_ref["dir"]}"
                    ;;

                [Nn])
                    :
                    ;;

                *)
                    printf "${BLUE}Invalid option. Try again.${ENDCOLOR}\n"
                    continue
                    ;;
            esac
            break
        done
    fi

    if [[ "${game_context_ref["status"]}" == "Orphan" ]]; then
        echo "TODO: implementar normalização do gamelist"
    
    elif [[ -n "${target_dir_context_ref["gamelist"]:-}" ]]; then
        if ! transfer_gamelist_entry \
            game_context_ref target_dir_context_ref; then
            return 1
        fi
        printf "${GREEN}gamelist.xml updated successfully${ENDCOLOR}\n"


    fi
    return 0

    # rsync -ah --info=progress2 --remove-source-files "${game_context_ref["path"]}" "${target_dir_context_ref["dir"]}"
    # rsync --remove-source-files é uma alternativa mais segura que mv,
    # pois copia os arquivos e só remove a origem após a transferência.
    # Atualmente não é utilizado porque requer espaço suficiente para manter
    # origem e destino simultaneamente durante a cópia.
    # Reavaliar essa abordagem futuramente.

}

cp_game() {
    local -n game_context_ref="$1"
    local -n target_dir_context_ref="$2"

    local answer=""

    printf "Copying ${GREEN}%s${ENDCOLOR} to ${GREEN}%s${ENDCOLOR}\n" \
    "${game_context_ref["name"]}" \
    "${target_dir_context_ref["dir"]}"

    if sudo rsync -ah --info=progress2 "${game_context_ref["path"]}" "${target_dir_context_ref["dir"]}"; then
        printf "${YELLOW}Game copied successfully!${ENDCOLOR}\n"
    else
        printf "${BLUE}Failed to copy game!${ENDCOLOR}\n"
        return 1
    fi
    
    if [[ -n "${game_context_ref["valid_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["orphan_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["linked_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["linked_support_count"]:-}" ]]; then

        printf "${RED}Do you want to copy all related files too? (y/n) ${ENDCOLOR}"
        while true; do
            read -r -p "-> " answer
            echo ""

            case "$answer" in
                [Yy])
                    process_related_files game_context_ref "cp" "${target_dir_context_ref["dir"]}"
                    ;;

                [Nn])
                    :
                    ;;

                *)
                    printf "${BLUE}Invalid option. Try again.${ENDCOLOR}\n"
                    continue
                    ;;
            esac
            break
        done
    fi

    if [[ "${game_context_ref["status"]}" == "Orphan" ]]; then
        echo "TODO: implementar normalização do gamelist"
    
    elif [[ -n "${target_dir_context_ref["gamelist"]:-}" ]]; then
        if ! transfer_gamelist_entry \
            game_context_ref target_dir_context_ref \
            false; then
            return 1
        fi
        printf "${GREEN}gamelist.xml updated successfully${ENDCOLOR}\n"


    fi
    return 0

}

rm_game() {
    local -n game_context_ref="$1"
    local -n target_dir_context_ref="$2"
    
    local answer=""

    printf "Deleting ${GREEN}%s${ENDCOLOR}\n" \
    "${game_context_ref["name"]}" \

    if sudo rm -f "${game_context_ref["path"]}"; then
        printf "${YELLOW}Game deleted successfully!${ENDCOLOR}\n"
    else
        printf "${BLUE}Failed to delete the game!${ENDCOLOR}\n"
        return 1
    fi

    if [[ -n "${game_context_ref["valid_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["orphan_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["linked_asset_count"]:-}" ]] || \
        [[ -n "${game_context_ref["linked_support_count"]:-}" ]]; then

        printf "${RED}Do you want to delete all related files too? (y/n) ${ENDCOLOR}"
        while true; do
            read -r -p "-> " answer
            echo ""

            case "$answer" in
                [Yy])
                    process_related_files game_context_ref "rm"
                    ;;

                [Nn])
                    :
                    ;;

                *)
                    printf "${BLUE}Invalid option. Try again.${ENDCOLOR}\n"
                    continue
                    ;;
            esac
            break
        done
    fi

    if [[ "${game_context_ref["status"]}" != "Orphan" ]]; then
        if ! rm_gamelist_entry \
            "${game_context_ref["path"]}"; then
            return 1
        fi
        printf "${GREEN}gamelist.xml updated successfully${ENDCOLOR}\n"


    fi
    return 0
}

show_game_metadata() {
    local game_name="$1"
    local xml_node="$2"
    printf "\n${YELLOW}────────────── %s Node ──────────────${ENDCOLOR}\n" "$game_name"
    printf "    %s\n" "$xml_node"
    printf "\n${YELLOW}─────────────────────────────────────${ENDCOLOR}\n"
    

}

edit_metadata() {
    local node="$1"
    local game_path="$2"

    local tmp_gamelist=""

    if ! duplicate_gamelist_with_entry \
        "$node" \
        "./gamelist.xml" \
        tmp_gamelist true; then
        return 1
    fi

    printf "${GREEN}Temporary gamelist.xml created and validated successfully!${ENDCOLOR}\n"

    if ! replace_gamelist \
        "./gamelist.xml" \
        "$tmp_gamelist"; then
        return 1
    fi

    printf "${YELLOW}Target gamelist.xml updated successfully!${ENDCOLOR}\n"

    if ! rm_gamelist_entry "$game_path"; then
        return 1
    fi
    printf "${YELLOW}Source gamelist.xml entry removed successfully!${ENDCOLOR}\n"

    return 0

}

add_to_gamelist() {
    local -n game_context_ref="$1"

    local tags=( "path" "name" "image" "video" "marquee" "thumbnail" )
    local tag=""
    local node=""
    local tmp_gamelist=""

    for tag in "${tags[@]}"; do
        case "$tag" in
            "path")
                node+="<game>"$'\n\t'"<path>${game_context_ref["path"]}</path>"$'\n'
                ;;

            "name")
                node+=$'\t'"<name>${game_context_ref["name"]}</name>"$'\n'
                ;;
        esac

        if [[ "${game_context_ref["linked_${tag}"]:-}" ]]; then
            node+=$'\t'"<$tag>${game_context_ref["linked_${tag}"]}</$tag>"$'\n'
        fi

        [[ "$tag" == "thumbnail" ]] && node+="</game>"
    done

    # TODO: adicionar pergunta sobre add mais entradas no xml 
    if ! duplicate_gamelist_with_entry \
        "$node" \
        "./gamelist.xml" \
        tmp_gamelist; then
        return 1
    fi

    printf "${GREEN}Temporary gamelist.xml created and validated successfully!${ENDCOLOR}\n"

    if ! replace_gamelist \
        "./gamelist.xml" \
        "$tmp_gamelist"; then
        return 1
    fi

    printf "${YELLOW}Target gamelist.xml updated successfully!${ENDCOLOR}\n"
    return 0
    
}

show_relatted_files() {
    local -n game_context_ref="$1"

    local suffixes=( "image" "video" "marquee" "thumbnail" "auxiliary" "configs" )
    local suffix=""
    local has_relative_files=""

    for suffix in "${suffixes[@]}"; do

        if [[ -n "${game_context_ref["valid_${suffix}"]:-}" ]]; then
            printf "Valid %s: ${PINK}%s${ENDCOLOR}\n" "$suffix" "${game_context_ref["valid_${suffix}"]}"
            has_relative_files=1
        fi

        if [[ -n "${game_context_ref["linked_${suffix}"]:-}" ]]; then
            printf "Linked %s: ${PINK}%s${ENDCOLOR}\n" "$suffix" "${game_context_ref["linked_${suffix}"]}"
            has_relative_files=1
        fi
   
    done

    if [[ -z "$has_relative_files" ]]; then
        printf "${BLUE}%s has no relative files associeted with${ENDCOLOR}\n" "${game_context_ref["name"]}"
    
    fi   
}

show_gamelist_data() {
    xmlstarlet sel -t -m "//game/*" -v "name()" -o ": " -v "normalize-space(.)" -n ./gamelist.xml \
    | awk -v C="${PINK}" -v E="${ENDCOLOR}" -F':' '
    BEGIN { game_num = 0 }
    $1 == "path" && NR > 0 { print "\n--- ENTRADA " ++game_num " ---" }
    { 
        gsub(/&amp;/, "\\&", $2)
        gsub(/&lt;/, "<", $2)
        gsub(/&gt;/, ">", $2)
        gsub(/&quot;/, "\"", $2)
        gsub(/&#39;/, "'\''", $2)
        print C $1 E ": " $2 
    }'
    return 0

}

find_games() {
    local -n dirs="$1"
    local -n games="$2"
    local target_game
    local lower_target
    local dir
    games=()

    read -r -p "Digite o nome do jogo: " target_game

    lower_target="${target_game,,}"


    for dir in "${dirs[@]}"; do

        local path=""
        local name=""
        while IFS='|' read -r path name; do

            path="${path#./}"
            local game_path="$dir$path"
                        
            if [[ -n "${games["$game_path"]:-}" ]]; then
                printf "${BLUE}DUPLICATA!!!!!!${ENDCOLOR}\n"
                printf "Name: ${CYAN}%s${ENDCOLOR}\nPath: ${PINK}%s${ENDCOLOR}\n\n" "$name" "$path"
                continue                   

            fi
            games["$game_path"]="$name"                        


        done < <(xmlstarlet sel -t -m "//game[contains(translate(name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '$lower_target')]" \
                    -v "path" -o "|" -v "name" -n ./"$dir"/gamelist.xml \
                    | sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')

    done
       
        local file
        find . -type f -iname "*$lower_target*" -print0 | while IFS= read -r -d '' file; do
                file=${file#./}

                printf "\n${RED}Testando:${ENDCOLOR} %s\n" "$file"

                if [[ -n "${games["$file"]:-}" ]]; then
                    printf "Arquivo já encontrado no xml: ${GREEN}%s${ENDCOLOR}\n" "${games["$file"]}"
                fi
            done

 
}

# Initial application state
STATE="LOOK"
PREV_STATE=""

main_menu() {
    # --------------------------------------------------------------------------
    # USER INTERACTION
    # --------------------------------------------------------------------------
    local user_answer=""
    local selected_system_dir=""
    local selected_game_name=""
    local selected_game_path=""

    local using_find=0 # Indicates whether execution originated from the "Find Games" workflow.

    # --------------------------------------------------------------------------
    # DIRECTORY DISCOVERY
    # --------------------------------------------------------------------------
    local dirs_list=(*/) # Immediate subdirectories in the current working directory.
    local dirs_with_games=()
    local dirs_without_games=()
    local dirs_to_look=()

    # --------------------------------------------------------------------------
    # GAME CLASSIFICATION PIPELINE
    # --------------------------------------------------------------------------
    local -A unclassified_files=()

    local -A xml_unclassified_games=()
    local -A valid_games=()
    local -A ghost_games=()

    local -A orphan_games=()

    # Maps a game file path to its display name.
    local -A game_library=()

    # --------------------------------------------------------------------------
    # XML ASSETS
    # --------------------------------------------------------------------------
    local -A unclassified_images=()
    local -A unclassified_videos=()
    local -A unclassified_marquees=()
    local -A unclassified_thumbnails=()

    local -A valid_images=()
    local -A valid_videos=()
    local -A valid_marquees=()
    local -A valid_thumbnails=()

    local -A orphan_images=()
    local -A orphan_videos=()
    local -A orphan_marquees=()
    local -A orphan_thumbnails=()

    local -A ghost_images=()
    local -A ghost_videos=()
    local -A ghost_marquees=()
    local -A ghost_thumbnails=()

    # --------------------------------------------------------------------------
    # FILES ASSOCIATED WITH KNOWN GAMES
    # --------------------------------------------------------------------------
    local -A linked_images=()
    local -A linked_videos=()
    local -A linked_marquees=()
    local -A linked_thumbnails=()

    local -A linked_auxiliary=()
    local -A linked_configs=()

    # --------------------------------------------------------------------------
    # FILES NOT ASSOCIATED WITH ANY GAME
    # --------------------------------------------------------------------------
    local -A unlinked_images=()
    local -A unlinked_videos=()
    local -A unlinked_marquees=()
    local -A unlinked_thumbnails=()

    local -A unlinked_auxiliary=()
    local -A unlinked_configs=()

    # --------------------------------------------------------------------------
    # UNKNOWN FILES
    # --------------------------------------------------------------------------
    local -A unknown_files=()

    # --------------------------------------------------------------------------
    # SYSTEM DATABASE
    # --------------------------------------------------------------------------
    # Loaded once and treated as read-only lookup tables throughout the application.
    local -Ag SYSTEM_PATHS=()
    local -Ag SYSTEM_NAMES=()
    local -Ag VALID_EXTENSIONS=()
    local -Ag VALID_SYSTEM_EXTENSIONS=()
    local -Ag SYSTEMS_BY_EXTENSION=()

    local -Ag AUX_CATEGORY=()
    local -Ag AUX_DESCRIPTION=()

    printf "Evaluating Directory:${GREEN} %s${ENDCOLOR}\n" "${PWD##*/}"
    printf "${YELLOW}%s Directories Found${ENDCOLOR}\n" "${#dirs_list[@]}"

    printf "Loading systems data...\n"
    load_systems_info
    load_aux_ext_file

    while true; do
        case "$STATE" in
            "LOOK")
            # Discover available systems and select the next workflow.

                echo "Scanning directories for ROMs..."

                # Separate directories based on whether they contain game files.
                classify_dirs_by_roms dirs_list dirs_with_games dirs_without_games

                printf "${YELLOW}%s Directories containing ROMs${ENDCOLOR}\n" "${#dirs_with_games[@]}"
                printf "${CYAN}%s Directories containing only 'gamelist.xml'${ENDCOLOR}\n" "${#dirs_without_games[@]}"

                ask_user "" user_answer \
                    "Browse Directories with ROMs" \
                    "Browse Directories without ROMs" \
                    "Find Game" \
                    "Overall Report"

                case "$user_answer" in
                    "Browse Directories with ROMs")
                        dirs_to_look=( "${dirs_with_games[@]}" )
                    ;;

                    "Browse Directories without ROMs")
                        dirs_to_look=( "${dirs_without_games[@]}" )
                    ;;

                    "Find Game")
                        using_find=1
                        dirs_to_look=( "${dirs_with_games[@]}" )
                        STATE="FIND_GAME"
                        continue
                    ;;

                    "Overall Report")
                    # Generate an overview of all detected systems.
                    # TODO: IMPLEMENTAR CORRETAMENTE DEPOIS
                        count_by_dir dirs_with_games

                        STATE="LOOK"
                        continue
                    ;;

                esac

                PREV_STATE="LOOK"
                STATE="CONSOLE_MENU"
            ;;

            "CONSOLE_MENU")
            # Allows the user to choose a console directory and enter in it.
                ask_user "Select a directory:" user_answer \
                    "${dirs_to_look[@]}" "Back"

                case "$user_answer" in
                    "Back")
                        STATE="LOOK"
                    ;;

                    *)
                        selected_system_dir="$user_answer"
                        printf "Entering directory ${GREEN}%s${ENDCOLOR}\n" "$selected_system_dir"
                        cd -- "$selected_system_dir" || exit 1
                        STATE="SYSTEM_DASHBOARD"
                    ;;
                esac

                PREV_STATE="CONSOLE_MENU"
            ;;

            "SYSTEM_DASHBOARD")
            # Analyzes the selected directory, builds the game library,
            # and presents the available management options.

                # NOTE:
                    # The directory analysis is treated as a shared analysis state. These
                    # high-level functions operate directly on that state to avoid forwarding
                    # dozens of arrays through the call chain. Helper functions continue to
                    # receive explicit parameters, preserving their modularity and reusability.
                if [[ "$PREV_STATE" == "CONSOLE_MENU" ]]; then
                    reset_analysis_state

                    analyze_directory "$selected_system_dir"
                
                fi

                print_directory_summary "$selected_system_dir"

                ask_user "" user_answer \
                    "Browse Games" \
                    "Browse Assets" \
                    "Browse Support Files" \
                    "Browse Unknows" \
                    "Back"   

                case "$user_answer" in
                    "Browse Games")
                        STATE="GAMES_COLLECTION_MENU"
                    ;;

                    "Browse Assets")
                        STATE="ASSETS_MENU"
                    ;;

                    "Browse Support Files")
                        STATE="SUPPORT_MENU"
                    ;;

                    "Browse Unknows")
                        STATE="UNKNOWS_MENU"
                    ;;

                    "Back")
                        printf "Returning to ${GREEN}%s${ENDCOLOR}\n" "$OLDPWD"
                        cd -- "$OLDPWD" || exit 1
                        STATE="CONSOLE_MENU"
                    ;;
                esac

                PREV_STATE="SYSTEM_DASHBOARD"
            ;;

            "GAMES_COLLECTION_MENU")
                local -A target_collection=()
                # TODO: add lógica p/ mostrar apenas opções pertinentes
                ask_user "" user_answer \
                    "All games" \
                    "Xml games" \
                    "Orphan games" \
                    "Ghost games" \
                    "Back"

                case "$user_answer" in
                    "All games")
                        build_target_collection game_library target_collection
                    ;;

                    "Xml games")
                        build_target_collection valid_games target_collection

                    ;;

                    "Orphan games")
                        build_target_collection orphan_games target_collection

                    ;;

                    "Ghost games")
                        build_target_collection ghost_games target_collection

                    ;;

                    "Back")
                        STATE="SYSTEM_DASHBOARD"
                        PREV_STATE="GAMES_COLLECTION_MENU"
                        continue

                    ;;
                esac
                STATE="GAMES_SELECTION_MENU"
                PREV_STATE="GAMES_COLLECTION_MENU"
            
            ;;

            "GAMES_SELECTION_MENU")
                sorted_games=()

                sort_games sorted_games "${!target_collection[@]}"

                ask_user "Selecione um jogo:" user_answer \
                    "${sorted_games[@]}" \
                    "Back"

                case "$user_answer" in
                    "Back")
                        STATE="SYSTEM_DASHBOARD"
                        PREV_STATE="GAMES_SELECTION_MENU"
                        continue

                    ;;

                    *)
                        selected_game_name="$user_answer"
                        selected_game_path="${target_collection["$selected_game_name"]}"

                        printf "Jogo selecionado: ${GREEN}%s${ENDCOLOR}\n" "$selected_game_name"
                        # printf "Arquivo selecionado: ${CYAN}%s${ENDCOLOR}\n" "$selected_game_path"

                    ;;
                esac
                STATE="GAME_ACTION_MENU"
                PREV_STATE="GAMES_SELECTION_MENU"

            ;;

            "GAME_ACTION_MENU")
            
                local -A game_context=()
                
                load_game_context  game_context "$selected_game_path" "$selected_game_name"
                print_game_context game_context


                # TODO: rever opções p/ ghost_games - ñ se move/copia oq ñ existe

                local menu_options=("Move Game" "Copy Game" "Delete Game" "Remove from gamelist.xml" )

                if [[ "${game_context["status"]}" !=  "Orphan" ]]; then
                    menu_options+=("See Metadata" "Edit Metadata")
                else
                    menu_options+=("Add to gamelist.xml")
                fi

                # TODO: reavaliar a fragilidade  do trecho, pois depende diretamente da arquitetura de game_context
                (( "${#game_context[@]}" > 3 )) &&  menu_options+=("See Related Files")
                
                local -A target_dir_context=()

                ask_user "" user_answer \
                    "${menu_options[@]}" "Back"

                case "$user_answer" in
                    "Move Game" | "Copy Game")
                        prepare_target_directory target_dir_context

                    ;;&
                    
                    "Move Game")
                        if mv_game game_context target_dir_context; then
                            printf "\n${GREEN}Operation completed successfully!${ENDCOLOR}\n"
                            printf "All requested operations were completed as expected.\n"
                        else
                            printf "\n${RED}Operation completed with errors!${ENDCOLOR}\n"
                            printf "Please review the messages above to identify which step failed.\n"
                        fi

                    ;;

                    "Copy Game")
                        if cp_game game_context target_dir_context; then
                            printf "\n${GREEN}Operation completed successfully!${ENDCOLOR}\n"
                            printf "All requested operations were completed as expected.\n"
                        else
                            printf "\n${RED}Operation completed with errors!${ENDCOLOR}\n"
                            printf "Please review the messages above to identify which step failed.\n"
                        fi

                    ;;

                    "Delete Game")
                        if rm_game game_context target_dir_context; then
                            printf "\n${GREEN}Operation completed successfully!${ENDCOLOR}\n"
                            printf "All requested operations were completed as expected.\n"
                        else
                            printf "\n${RED}Operation completed with errors!${ENDCOLOR}\n"
                            printf "Please review the messages above to identify which step failed.\n"
                        fi
                    ;;

                    "See Metadata")
                        show_game_metadata "${game_context["name"]}" "${game_context["xml_node"]}"
                    ;;

                    "Edit Metadata")
                        if edit_metadata "${game_context["xml_node"]}" "${game_context["path"]}"; then
                            printf "\n${GREEN}Operation completed successfully!${ENDCOLOR}\n"
                            printf "All requested operations were completed as expected.\n"
                        else
                            printf "\n${RED}Operation completed with errors!${ENDCOLOR}\n"
                            printf "Please review the messages above to identify which step failed.\n"
                        fi
                    ;;

                    "Add to gamelist.xml")
                        add_to_gamelist game_context
                    ;;

                    "Remove from gamelist.xml")
                        rm_gamelist_entry "${game_context["path"]}"
                    ;;

                    "See Related Files")
                        show_relatted_files game_context

                    ;;

                    "Back")
                        if (( using_find )); then
                            printf "Voltando p/ ${GREEN}%s${ENDCOLOR}\n" "$OLDPWD"
                            cd "$OLDPWD" || exit 1
                        
                        fi
                        STATE="GAMES_MENU"
                    ;;

                esac
                printf "Returning to ${GREEN}%s${ENDCOLOR}\n" "$OLDPWD"
                cd -- "$OLDPWD" || exit 1
                STATE="LOOK"
                PREV_STATE="GAME_ACTION_MENU"
            ;;

            # "GAMELIST_MENU")
                #     ask_user "" user_answer "Usar VS Code" "Ver Entradas" "Deletar gamelist.xml" "Voltar"
                #     case "$user_answer" in
                #             "Usar VS Code")
                #                 code --wait ./gamelist.xml \
                #                     && printf "${YELLOW}Entrada atualizada com sucesso!${ENDCOLOR}\n"
                #                 STATE="GAMELIST_MENU"
                #             ;;

                #             "Ver Entradas")
                #                 show_gamelist_data
                #                 STATE="GAMELIST_MENU"
                #             ;;

                #             "Deletar gamelist.xml")
                #                 echo "sudo rm ./gamelist.xml"
                #                 STATE="GAMELIST_MENU"
                #             ;;

                #             "Voltar")
                #                 STATE="DIR_ACTION"                        
                #             ;;

                #     esac

                #     PREV_STATE="GAMELIST_MENU"
            # ;;

            # "FIND_GAME")
                #     find_games dirs_to_look game_library

                #     if [[ "${#game_library[@]}" -lt 1 ]]; then
                #         printf "${BLUE}Nenhum jogo encontrado.${ENDCOLOR}\n"
                #     else
                #         printf "${YELLOW}%s jogos encontrados${ENDCOLOR}\n" "${#game_library[@]}"
                #         STATE="GAMES_MENU"    

                #     fi   

                #     PREV_STATE="FIND_GAME" 
            # ;;

        esac
    done

    # if (( using_find )); then
        #     using_find=0
        #     STATE="LOOK"
        #     continue  
        # fi
        # if (( using_find )); then
        #     printf "Entrando na pasta${GREEN} %s${ENDCOLOR}\n" "${selected_game_path%%/*}"
        #     cd -- "./${selected_game_path%%/*}" || exit 1  
        # fi

}
main_menu "$@"