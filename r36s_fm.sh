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
    select opt in "${options[@]}"; do
        # Ignore invalid menu indexes.
        if is_valid_option "$REPLY" "$#";then
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
    # stages progressively move entries from this collection into their respective
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

load_xml_entries() {
# Loads gamelist.xml metadata and stores exactly as they appear, preserving the relative
# path format (e.g. "./game.zip") used throughout the pipeline.
    local -n xml_unclassified_entries_ref="$1"
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
        # are missing. So, ignore entries without a valid ROM game_path
        [[ -n "$game_path" ]] && xml_unclassified_entries_ref["$game_path"]="$game_name"
        
        # Store only existing asset paths to avoid unnecessary empty entries.
        [[ -n "$image_path" ]] && unclassified_images_ref["$game_path"]="$image_path"
        [[ -n "$video_path" ]] && unclassified_videos_ref["$game_path"]="$video_path"
        [[ -n "$marquee_path" ]] && unclassified_marquees_ref["$game_path"]="$marquee_path"
        [[ -n "$thumbnail_path" ]] && unclassified_thumbnails_ref["$game_path"]="$thumbnail_path"
        

    done < <(xmlstarlet sel -t -m "//game" -v "path" -o "|" -v "name" -o "|" -v "image" \
                -o "|" -v "video" -o "|" -v "marquee" -o "|" -v "thumbnail" -n ./gamelist.xml | \
                sed 's/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&apos;/'\''/g')
        # Decode XML entities (e.g. $amp) so asset game_paths match the actual filesystem names.
}

classify_xml_entries() {
# Match XML entries against the discovered files.
    local -n unclassified_files_ref="$1"
    local -n xml_unclassified_entries_ref="$2"
    local -n xml_valid_games_ref="$3"
    local -n xml_ghost_entries_ref="$4"
    local system="$5"

    local game_path=""
    local game_name=""
    local game_extension=""

    local -A processed_game_names=()

    # Normalize the directory name to match VALID_SYSTEM_EXTENSIONS keys.
    system="${system%%/*}"

    for game_path in "${!xml_unclassified_entries_ref[@]}"; do
        game_extension="${game_path##*.}"

        if [[ -n "${unclassified_files_ref["$game_path"]:-}" ]] &&
           [[ -n "${VALID_SYSTEM_EXTENSIONS["$system:.$game_extension"]:-}" ]]; then

            game_name="${xml_unclassified_entries_ref["$game_path"]}"

            if [[ -z "${processed_game_names["$game_name"]:-}" ]]; then
            # Entries with an existing file and a valid extension are classified as valid games.
                xml_valid_games_ref["$game_path"]="$game_name"
                processed_game_names["$game_name"]=1

            else
                # When multiple ROMs share the same name, append the file
                # extension to keep their names unique and expose the duplicate.
                xml_valid_games_ref["$game_path"]="$game_name.$game_extension"

            fi
            unset 'unclassified_files_ref[$game_path]'

        else
        # Otherwise, they are treated as ghost entries.
            xml_ghost_entries_ref["$game_path"]="$game_name"
        fi

        unset 'xml_unclassified_entries_ref["$game_path"]'
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
    local -n xml_valid_games_ref="$6"

    local game_path=""
    local asset_path=""

    for game_path in "${!unclassified_assets_ref[@]}"; do
        asset_path="${unclassified_assets_ref[$game_path]}"

        if [[ -n "${unclassified_files_ref["$asset_path"]:-}" ]]; then

            if [[ -n "${xml_valid_games_ref["$game_path"]:-}" ]]; then
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
    local -n xml_valid_games_ref="$1"
    local -n orphan_games_ref="$2"
    local -n game_library_ref="$3"
    
    local game_path=""
    local game_name=""

    for game_path in "${!xml_valid_games_ref[@]}"; do
        game_name="${xml_valid_games_ref[$game_path]}"
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
                    linked_configs_ref["$game_path"]="$file"
                    ;;

                # ====================================================================
                # Auxiliary Files
                # Files associated with the game or the user.
                # ====================================================================
                "SAVE" | "SAVE_STATE" | "HIGH_SCORE" | "DIFF" | "CHEAT" | "REPLAY" | "PATCH" | \
                "DISC_DESCRIPTOR" | "DISC_METADATA" | "PLAYLIST" | "AUDIO" | "ARTWORK" | \
                "FONT" | "DOCUMENT" | "LOG" | "BACKUP")
                    linked_auxiliary_ref["$game_path"]="$file"
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
    xml_unclassified_entries=()

    # Game classification.
    xml_valid_games=()
    xml_ghost_entries=()
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

    # Load and classify gamelist.xml entries.
    load_xml_entries \
        xml_unclassified_entries \
        unclassified_images \
        unclassified_videos \
        unclassified_marquees \
        unclassified_thumbnails

    classify_xml_entries \
        unclassified_files \
        xml_unclassified_entries \
        xml_valid_games \
        xml_ghost_entries \
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
            xml_valid_games
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
        xml_valid_games \
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
# Prints a formatted summary line.
    local label="$1"
    local value="$2"
    local color="${3:-}"

    printf "  %-30s " "${label}:"

    if [[ -n "$color" ]]; then
        printf "%b%6d%b\n" "$color" "$value" "$ENDCOLOR"
    else
        printf "%6d\n" "$value"
    fi
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
    print_summary_line "XML Games"         "${#xml_valid_games[@]}"

    local color=""

    color=""
    (( ${#orphan_games[@]} > 0 )) && color="$YELLOW"
    print_summary_line "Orphan Games" "${#orphan_games[@]}" "$color"

    color=""
    (( ${#xml_ghost_entries[@]} > 0 )) && color="$RED"
    print_summary_line "Ghost XML Entries" "${#xml_ghost_entries[@]}" "$color"

    printf "\n${YELLOW}────────────── Assets ─────────────${ENDCOLOR}\n"

    print_summary_line "Valid Images"       "${#valid_images[@]}"
    print_summary_line "Valid Videos"       "${#valid_videos[@]}"
    print_summary_line "Valid Marquees"     "${#valid_marquees[@]}"
    print_summary_line "Valid Thumbnails"   "${#valid_thumbnails[@]}"
    echo ""
    print_summary_line "Orphan Images"       "${#orphan_images[@]}"
    print_summary_line "Orphan Videos"       "${#orphan_videos[@]}"
    print_summary_line "Orphan Marquees"     "${#orphan_marquees[@]}"
    print_summary_line "Orphan Thumbnails"   "${#orphan_thumbnails[@]}"
    echo ""
    print_summary_line "Linked Images"       "${#linked_images[@]}"
    print_summary_line "Linked Videos"       "${#linked_videos[@]}"
    print_summary_line "Linked Marquees"     "${#linked_marquees[@]}"
    print_summary_line "Linked Thumbnails"   "${#linked_thumbnails[@]}"
    echo ""
    print_summary_line "Unlinked Images"     "${#unlinked_images[@]}"
    print_summary_line "Unlinked Videos"     "${#unlinked_videos[@]}"
    print_summary_line "Unlinked Marquees"   "${#unlinked_marquees[@]}"
    print_summary_line "Unlinked Thumbnails" "${#unlinked_thumbnails[@]}"

    printf "\n${YELLOW}────────── Support Files ──────────${ENDCOLOR}\n"

    print_summary_line "Linked Auxiliary"    "${#linked_auxiliary[@]}"
    print_summary_line "Unlinked Auxiliary"  "${#unlinked_auxiliary[@]}"
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
        xml_unclassified_entries=()
        xml_valid_games=()
        xml_ghost_entries=() 
        orphan_games=()
        game_library=()

        local -A unclassified_images=() unclassified_videos=() unclassified_marquees=() unclassified_thumbnails=()
        local -A valid_images=() valid_videos=() valid_marquees=() valid_thumbnails=()
        local -A unlinked_images=() unlinked_videos=() unlinked_marquees=() unlinked_thumbnails=()
        local -A ghost_images=() ghost_videos=() ghost_marquees=() ghost_thumbnails=()

        get_all_files unclassified_files 
        
        load_xml_entries xml_unclassified_entries unclassified_images unclassified_videos unclassified_marquees unclassified_thumbnails

        classify_xml_entries unclassified_files xml_unclassified_entries xml_valid_games xml_ghost_entries "$dir"

        local assets_names=( "images" "videos" "marquees" "thumbnails" )
        local name=""
        # certeza q tem forma de abstrair classify_xml_asset() p/ q lide com todos os assets de uma vez, mas por enquanto isso serve
        for name in "${assets_names[@]}"; do
            local -n arr_ref="unclassified_${name}"
            # printf "Tamanho de %s: %d\n" "${!arr_ref}" "${#arr_ref[@]}"
            # se ñ há assets p/ serem classificados, ñ há necessidade de classificar oq não existe
            (( ${#arr_ref[@]} > 0 )) && classify_xml_asset unclassified_files unclassified_${name} valid_${name} orphan_${name} ghost_${name} xml_valid_games
        done

        local -A possible_roms=() grouped_possible_roms=() grouped_valid_games=() config_files=()
        
        extract_possible_roms unclassified_files possible_roms "$dir"
        group_files possible_roms grouped_possible_roms
        classify_possible_roms grouped_possible_roms orphan_games config_files
        build_game_library xml_valid_games orphan_games game_library

        total_games+="${#game_library[@]}"

        printf "\n========== ${GREEN}%s${ENDCOLOR} ==========\n" "$dir"
        printf "XML válidos      : %d\n" "${#xml_valid_games[@]}"
        printf "Jogos órfãos     : %d\n" "${#orphan_games[@]}"
        printf "Entradas fantasma: %d\n" "${#xml_ghost_entries[@]}"
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

create_gamelist() {
# Cria um gamelist.xml básico em um diretório especificado
    local target="$1"
    printf "Criando${GREEN} %s${ENDCOLOR}\n" "$target"

sudo tee "$target" > /dev/null <<EOF
<?xml version="1.0" encoding="utf-8"?>
<gameList>
</gameList>
EOF
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

duplicate_xml_with_entry() {
# Cria uma cópia do gamelist.xml com a entrada de um jogo anexada como arquivo temporário
    local game="$1"
    local tgt_file="$2"
    local open_vscode="${3:-false}" # flag q controla a edição de metadados
    printf "Criando arquivos temporários necessários...\n"

    # Arquivos temporários seguros
    tmp_game="$(mktemp --tmpdir game.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_game"

    tmp_xsl="$(mktemp --tmpdir append.XXXXXX.xsl)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_xsl"

    tmp_output_raw="$(mktemp --tmpdir out_raw.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_output_raw"

    tmp_output_fmt="$(mktemp --tmpdir out_fmt.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_output_fmt"

    # 1) Extrai o <game> para o temporário
    printf "Extraindo entrada do jogo selecionado...\n"

    local safe_xpath
    safe_xpath=$(escape_xpath_string "$game")
    xmlstarlet sel -t -c "//game[name=$safe_xpath]" "./gamelist.xml" > "$tmp_game"

    if "$open_vscode"; then
        code --wait "$tmp_game"
    fi

    printf "Criando cópia do gamelist.xml de destino com a entrada anexada...\n"
    # 2) cria o XSLT via heredoc
# AVISO: Se der tab no heredoc, o XSLT fica inválido e apaga o gamelist.xml alvo !!!
cat > "$tmp_xsl" <<'XSL'
<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet xmlns:xsl="http://www.w3.org/1999/XSL/Transform" version="1.0">
  <xsl:output method="xml" indent="yes"/>

  <xsl:template match="@*|node()">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
    </xsl:copy>
  </xsl:template>

  <xsl:template match="gameList">
    <xsl:copy>
      <xsl:apply-templates select="@*|node()"/>
      <xsl:apply-templates select="document('%%tmp_game%%')/game"/>
    </xsl:copy>
  </xsl:template>

</xsl:stylesheet>
XSL

    # 2.1) Substitui o placeholder pelo caminho do arquivo temporário do jogo
    sed -i "s|%%tmp_game%%|$tmp_game|g" "$tmp_xsl"

    # 3) Aplica o XSLT ao arquivo destino e grava em tmp_output_raw

    xsltproc "$tmp_xsl" "$tgt_file" > "$tmp_output_raw"

    # 4) Formata o XML de saída corretamente
    xmlstarlet fo -t --encode utf-8 "$tmp_output_raw" > "$tmp_output_fmt"

    # 5) (opcional) backup do original
    #cp -a "$tgt_file" "${tgt_file}.bak.$(date +%s)" 

    # 6) Valida o XML final
    if xmlstarlet val -q "$tmp_output_fmt"; then
        return 0
    else
        printf "${BLUE}Erro: O arquivo temporário não é um XML válido. Operação Cancelada.${ENDCOLOR}\n"
        exit 1
    fi
    
}

mv_xml_entry() {
# Move a entrada do gamelist.xml temporário para o arquivo de destino
    local tgt_file="$1"
    
    # TODO: Lidar com erro de permissão ao invés de ignorar - eventualmente =)
    if sudo mv "$tmp_output_fmt" "$tgt_file" 2>/dev/null; then
        return 0
    else
        printf "${BLUE}Erro ao mover o arquivo temporário para o destino. Verifique permissões.${ENDCOLOR}\n"
        exit 1
    fi
}

rm_xml_entry() {
# Remove a entrada do gamelist.xml original
    local game="$1"
    printf "${CYAN}Removendo entrada do gamelist.xml...${ENDCOLOR}\n"

    
    local safe_xpath
    safe_xpath=$(escape_xpath_string "$game")    

    if sudo xmlstarlet ed --inplace -d "(//game[name=$safe_xpath])[1]" "./gamelist.xml"; then
        return 0
    else
        printf "${BLUE}Erro ao remover a entrada do gamelist.xml. Verifique permissões ou integridade do arquivo.${ENDCOLOR}\n"
        exit 1
    fi
}

process_other_files() {
# Jogos podem conter arquivos relacionados como imgs ou videos ou nenhum
# É preciso descobrir se existem e move-los junto
   local game_xml="$1"
   local tg_dir="$2"
   local command="$3"
   printf "Verificando e processando arquivos relacionados ao jogo... \n"

    # Extrai os valores dos elementos filhos do <game> que não sejam <path>, <name>, <desc>ou scrap
    # path e name já são utilizadas, desc pode conter texto longo e scrap aparece como se fosse arquivo - por isso foram excluídos
    local other_files=()
    local file=""

    mapfile -t other_files < <(xmlstarlet sel -t \
                    -m "//game/*[starts-with(normalize-space(.), \"./\") and \
                        not(self::name or self::path or self::desc or self::scrap)]" \
                    -v "." -n "$game_xml")

    
    # TODO: passar selected_game_path EXPLICITAMENTE!!!
    # Alguns jogos possuem arquivos como fileName.iso e fileName.cue q devem ser processados tbm
    local name="${selected_game_path%.*}"
    mapfile -t -O "${#other_files[@]}" other_files < <(find . -type f -path "$name.*")
    
    if [[ "${#other_files[@]}" -eq 0 ]]; then
        printf "${CYAN}Nenhum arquivo relacionado encontrado.${ENDCOLOR}\n"
        return 0
    else

        local -A seen
        local unique=()
        local other=""

        for other in "${other_files[@]}"; do
        # Remove duplicatas, pois alguns jogos possuem duas ou mais tags q apontam p/ mesmo arquivo ou foram achados novamente pelo segundo mapfile
        # Tbm checa se o arquivo realmente existe, pq né, num vai processar oq ñ tá lá =)
            if [[ -z "${seen[$other]:-}" ]] && [[ "$other" != "./$selected_game_path" ]] && [[ -e "$other" ]]; then
                seen[$other]=1                         
                unique+=("$other")
            fi
        done

        other_files=("${unique[@]}")

        printf "Foram encontrados ${GREEN}%s arquvios relacionados${ENDCOLOR}\n" "${#other_files[@]}"
        printf "${PINK}%s${ENDCOLOR}\n" "${other_files[@]}"

        for other in "${other_files[@]}"; do

            local sub_dir="${other%/*}" # Remove o nome do arquivo, ficando só com o diretório
            sub_dir="${sub_dir#./}" # Remove o prefixo ./

            local target_sub_dir=""
            
            if [[  "$sub_dir" =~ ^\. ]]; then # Decide entre usar o diretório principal como destino ou um subdiretório
                target_sub_dir="$tg_dir"
            else
                target_sub_dir="$tg_dir/$sub_dir"
            fi
                
            case "$command" in
                cp|mv)
                    if [[ ! -d "$target_sub_dir" ]]; then
                        printf "${CYAN}Criando diretório %s${ENDCOLOR}\n" "$target_sub_dir"
                        sudo mkdir -p "$target_sub_dir"
                    fi
                    ;;&
                mv)
                    
                    printf "Movendo ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$other" "$target_sub_dir"
                    sudo "$command" "$other" "$target_sub_dir"
                    continue
                    ;;
                cp)
                    
                    printf "Copiando ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$other" "$target_sub_dir"
                    sudo "$command" "$other" "$target_sub_dir"
                    continue
                    ;;
                rm)
                    
                    printf "Removendo ${GREEN}%s${ENDCOLOR}${ENDCOLOR}\n" "$other"
                    sudo "$command" "$other"
                    continue
                    ;;
            esac
            
        done

        printf "${YELLOW}Arquivos relacionados processados com sucesso!${ENDCOLOR}\n"
        return 0
    fi


}

mv_game() {
# Move um jogo e sua entrada no gamelist.xml para um diretório de destino.
    # Parâmetros:
    #   $1 - Nome do jogo
    #   $2 - Caminho do arquivo do jogo
    local selected_game="$1"
    local selected_path="$2"
    local target_dir=""

    while true; do
        read -r -p "Digite o diretório de destino: " target_dir
        if [[ ! -d "$target_dir" ]]; then
            printf "${BLUE}Diretório não encontrado. Tente novamente.${ENDCOLOR}\n"
            continue
        fi
        break
    done

    local target_file="$target_dir/gamelist.xml" # gamelist.xml no diretório de destino
    if [[ -f "$target_file" ]]; then
        printf "${YELLOW}Arquivo gamelist encontrado no destino...${ENDCOLOR}\n"
    else
        printf "${CYAN}Nenhum gamelist.xml encontrado no destino.${ENDCOLOR}\n"
        create_gamelist "$target_file"
    fi

    duplicate_xml_with_entry "$selected_game" "$target_file" && \
        printf "${GREEN}Arquivo temporário validado com sucesso!${ENDCOLOR}\n"
        
    mv_xml_entry "$target_file" && \
        printf "${YELLOW}Entrada movida com sucesso para %s${ENDCOLOR}\n" "$target_file"

    rm_xml_entry "$selected_game" && \
        printf "${YELLOW}Entrada removida do arquivo de origem com sucesso!${ENDCOLOR}\n"

   
    process_other_files "$tmp_game" "$target_dir" "mv" #tmp_game é criado pelo duplicate_xml...
    
    printf "Movendo ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$selected_game" "$target_dir"
    sudo mv "$selected_path" "$target_dir" && \
        printf "${YELLOW}Jogo movido com sucesso!${ENDCOLOR}\n"
    # rsync -ah --info=progress2 --remove-source-files "$selected_path" "$target_dir/"
    # Dá p/ usar o comando acima - mais seguro - porém deu problema devido a espaço de armazenamento
    # Resolver eventualmente =)

}

cp_game() {
# Copia um jogo e sua entrada no gamelist.xml para um diretório de destino.
    # Parâmetros:
    #   $1 - Nome do jogo
    #   $2 - Caminho do arquivo do jogo
    local selected_game="$1"
    local selected_path="$2"
    local target_dir=""

    while true; do
        read -r -p "Digite o diretório de destino: " target_dir
        if [[ ! -d "$target_dir" ]]; then
            printf "${BLUE}Diretório não encontrado. Tente novamente.${ENDCOLOR}\n"
            continue
        fi
        break
    done

    local target_file="$target_dir/gamelist.xml" # gamelist.xml no diretório de destino
    if [[ -f "$target_file" ]]; then
        printf "${YELLOW}Arquivo gamelist encontrado no destino...${ENDCOLOR}\n"
    else
        printf "${CYAN}Nenhum gamelist.xml encontrado no destino.${ENDCOLOR}\n"
        create_gamelist "$target_file"
    fi

    duplicate_xml_with_entry "$selected_game" "$target_file" && \
        printf "${GREEN}Arquivo temporário validado com sucesso!${ENDCOLOR}\n"
        
    mv_xml_entry "$target_file" && \
        printf "${YELLOW}Entrada movida com sucesso para %s${ENDCOLOR}\n" "$target_file"

    process_other_files "$tmp_game" "$target_dir" "cp" #tmp_game é criado pelo mv_xml_entry
    
    printf "Copiando ${GREEN}%s${ENDCOLOR} para ${GREEN}%s${ENDCOLOR}\n" "$selected_game" "$target_dir"  
    sudo rsync -ah --info=progress2 "./$selected_path" "$target_dir/" && \
        printf "${YELLOW}Jogo Copiado com sucesso!${ENDCOLOR}\n"

}

rm_game() {
# Remove um jogo e sua entrada no gamelist.xml.
    # Parâmetros:
    #   $1 - Nome do jogo
    #   $2 - Caminho do arquivo do jogo
    local selected_game="$1"
    local selected_path="$2"

    printf "Criando xml temporário...\n" # Necessário por conta de process_other_files
    tmp_game="$(mktemp --tmpdir game.XXXXXX.xml)" && \
        printf "%s ---> ${GREEN}Sucesso!${ENDCOLOR}\n" "$tmp_game"

    printf "Extraindo entrada do jogo selecionado...\n"

    local safe_xpath
    safe_xpath=$(escape_xpath_string "$selected_game")
    xmlstarlet sel -t -c "//game[name=$safe_xpath]" "./gamelist.xml" > "$tmp_game"

    rm_xml_entry "$selected_game" && \
        printf "${YELLOW}Entrada removida com sucesso!${ENDCOLOR}\n"

    process_other_files "$tmp_game" "$selected_path" "rm"

    sudo rm -f "$selected_path" && \
        printf "${YELLOW}Jogo removido com sucesso!${ENDCOLOR}\n"

    rm -f "$tmp_game" && \
        printf "${YELLOW}Arquivo temporário removido com sucesso!${ENDCOLOR}\n"
}

show_game_metadata() {
    local game="$1"
    printf "\nDados sobre: ${GREEN}%s${ENDCOLOR}\n" "$game"
    
    local safe_xpath
    safe_xpath=$(escape_xpath_string "$game")
    xmlstarlet sel -t -m "//game[name=$safe_xpath]" -m "*" \
    -v "name()" -o ": " -v "normalize-space(.)" -n -b ./gamelist.xml \
    | awk -v C="${PINK}" -v E="${ENDCOLOR}" -F':' '{ 
    gsub(/&amp;/, "\\&", $2)
    gsub(/&lt;/, "<", $2)
    gsub(/&gt;/, ">", $2)
    gsub(/&quot;/, "\"", $2)
    gsub(/&#39;/, "'\''", $2)
    print C $1 E ": " $2 
    }'
    return 0

}

edit_metadata() {
    local game="$1"

    duplicate_xml_with_entry "$game" "./gamelist.xml" "true" && \
        printf "${YELLOW}Arquivo temporário validado com sucesso!${ENDCOLOR}\n"

    mv_xml_entry "./gamelist.xml" && \
        printf "${YELLOW}Entrada atualizada com sucesso!${ENDCOLOR}\n"
    
    rm_xml_entry "$game" && \
        printf "${YELLOW}Entrada removida do arquivo de origem com sucesso!${ENDCOLOR}\n"    

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

# Initial aplcation state
STATE="LOOK"

main_menu() {
    # --------------------------------------------------------------------------
    # USER INTERACTION
    # --------------------------------------------------------------------------
    local user_answer=""
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

    local -A xml_unclassified_entries=()
    local -A xml_valid_games=()
    local -A xml_ghost_entries=()

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
                    "Overall Report" \
                    "Exit"

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
                        count_by_dir dirs_with_games

                        STATE="LOOK"
                        continue
                    ;;

                    "Exit")
                        echo "Exiting program..."
                        exit 0
                    ;;

                esac

                STATE="CONSOLE_MENU"
            ;;

            "CONSOLE_MENU")
            # Allows the user to choose a console directory and enter in it.
                ask_user "Select a directory:" user_answer \
                    "${dirs_to_look[@]}" "Back" "Exit"

                case "$user_answer" in
                    "Back")
                        STATE="LOOK"
                    ;;

                    "Exit")
                        echo "Exiting program..."
                        exit 0
                    ;;

                    *)
                        printf "Entering directory ${GREEN}%s${ENDCOLOR}\n" "$user_answer"
                        cd -- "$user_answer" || exit 1
                        STATE="DIR_ACTION"
                    ;;
                esac
            ;;

            "DIR_ACTION")
            # Analyzes the selected directory, builds the game library,
            # and presents the available management options.

                # NOTE:
                    # The directory analysis is treated as a shared analysis state. These
                    # high-level functions operate directly on that state to avoid forwarding
                    # dozens of arrays through the call chain. Helper functions continue to
                    # receive explicit parameters, preserving their modularity and reusability.
                reset_analysis_state

                analyze_directory "$user_answer"

                print_directory_summary "$user_answer"
                
                ask_user "" user_answer \
                    "Browse Games" \
                    "Edit gamelist.xml" \
                    "Back" \
                    "Exit"

                case "$user_answer" in
                    "Browse Games")
                        STATE="GAMES_MENU"
                    ;;

                    "Edit gamelist.xml")
                        STATE="GAMELIST_MENU"
                    ;;

                    "Back")
                        printf "Returning to ${GREEN}%s${ENDCOLOR}\n" "$OLDPWD"
                        cd -- "$OLDPWD" || exit 1
                        STATE="CONSOLE_MENU"
                    ;;

                    "Exit")
                        echo "Exiting program..."
                        exit 0
                    ;;
                esac
            ;;

            "GAMES_MENU")
                sorted_games=()                
                sort_games sorted_games "${game_library[@]}"

                ask_user "Selecione um jogo:" user_answer "${sorted_games[@]}" "Voltar"
                case "$user_answer" in
                    "Voltar")
                        if (( using_find )); then
                            using_find=0
                            STATE="LOOK"
                            continue
                            
                        fi
                        STATE="DIR_ACTION"
                    ;;

                    *)
                        selected_game_name="$user_answer"

                        for file in "${!game_library[@]}"; do # Vale lembrar q a chave/arquivo é igual ao path do gamelist.xmlz
                            if [[ "${game_library[$file]}" == "$selected_game_name" ]]; then
                                selected_game_path="$file"
                                break
                            fi
                        done

                        printf "Jogo selecionado: ${GREEN}%s${ENDCOLOR}\n" "$selected_game_name"
                        printf "Arquivo selecionado: ${CYAN}%s${ENDCOLOR}\n" "$selected_game_path"
                       
                        if (( using_find )); then
                            printf "Entrando na pasta${GREEN} %s${ENDCOLOR}\n" "${selected_game_path%%/*}"
                            cd -- "./${selected_game_path%%/*}" || exit 1
                            
                        fi
                        STATE="GAME_ACTION"
                    ;;

                esac
            ;;

            "GAME_ACTION")

                ask_user "" user_answer "Ver metadados" "Editar metadados" "Mover jogo" "Copiar jogo" "Deletar jogo" "Voltar"
                case "$user_answer" in
                        "Ver metadados")
                            show_game_metadata "$selected_game_name"
                            STATE="GAME_ACTION"
                            ;;

                        "Editar metadados")
                            edit_metadata "$selected_game_name"
                            STATE="DIR_ACTION"
                            ;;

                        "Mover jogo")
                            mv_game "$selected_game_name" "$selected_game_path"
                            STATE="DIR_ACTION"
                            ;;

                        "Copiar jogo")
                            cp_game "$selected_game_name" "$selected_game_path"
                            STATE="DIR_ACTION"
                            ;;

                        "Deletar jogo")
                            rm_game "$selected_game_name" "$selected_game_path"
                            STATE="DIR_ACTION"
                            ;;

                        "Voltar")
                            if (( using_find )); then
                                printf "Voltando p/ ${GREEN}%s${ENDCOLOR}\n" "$OLDPWD"
                                cd "$OLDPWD" || exit 1
                            
                            fi
                            STATE="GAMES_MENU"
                            ;;

                    esac
            ;;

            "GAMELIST_MENU")
                ask_user "" user_answer "Usar VS Code" "Ver Entradas" "Deletar gamelist.xml" "Voltar"
                case "$user_answer" in
                        "Usar VS Code")
                            code --wait ./gamelist.xml \
                                && printf "${YELLOW}Entrada atualizada com sucesso!${ENDCOLOR}\n"
                            STATE="GAMELIST_MENU"
                        ;;

                        "Ver Entradas")
                            show_gamelist_data
                            STATE="GAMELIST_MENU"
                        ;;

                        "Deletar gamelist.xml")
                            echo "sudo rm ./gamelist.xml"
                            STATE="GAMELIST_MENU"
                        ;;

                        "Voltar")
                            STATE="DIR_ACTION"                        
                        ;;

                esac
            ;;

            "FIND_GAME")
                find_games dirs_to_look game_library

                if [[ "${#game_library[@]}" -lt 1 ]]; then
                    printf "${BLUE}Nenhum jogo encontrado.${ENDCOLOR}\n"
                else
                    printf "${YELLOW}%s jogos encontrados${ENDCOLOR}\n" "${#game_library[@]}"
                    STATE="GAMES_MENU"    

                fi    
            ;;

        esac
    done

}
main_menu "$@"