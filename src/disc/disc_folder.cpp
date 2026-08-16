#include "sf/disc/disc_folder.hpp"

#include "sf/core/error.hpp"
#include "sf/disc/cue_sheet.hpp"

#include <algorithm>
#include <cctype>
#include <string>
#include <system_error>
#include <vector>

namespace sf::disc {
namespace {

bool hasCueExtension(const std::filesystem::path& path) {
    auto extension = path.extension().string();
    std::ranges::transform(extension, extension.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return extension == ".cue";
}

std::filesystem::path checkedCanonical(const std::filesystem::path& path,
                                       const char* description) {
    std::error_code error;
    auto canonical = std::filesystem::weakly_canonical(path, error);
    if (error) {
        throw core::Error{core::ErrorCode::io,
                          std::string{"Cannot resolve "} + description};
    }
    return canonical;
}

bool isWithin(const std::filesystem::path& folder,
              const std::filesystem::path& candidate) {
    const auto relative = candidate.lexically_relative(folder);
    if (relative.empty() || relative.is_absolute()) {
        return false;
    }
    const auto first = relative.begin();
    return first != relative.end() && *first != "..";
}

} // namespace

CueBinPair discoverCueBinPair(const std::filesystem::path& folder_path) {
    std::error_code error;
    if (!std::filesystem::is_directory(folder_path, error) || error) {
        throw core::Error{core::ErrorCode::not_found,
                          "Selected disc location is not an accessible folder"};
    }

    std::vector<std::filesystem::path> cue_paths;
    std::filesystem::directory_iterator iterator{folder_path, error};
    const std::filesystem::directory_iterator end;
    if (error) {
        throw core::Error{core::ErrorCode::io,
                          "Cannot enumerate the selected disc folder"};
    }
    while (iterator != end) {
        const auto& entry = *iterator;
        std::error_code type_error;
        const auto status = entry.symlink_status(type_error);
        if (type_error) {
            throw core::Error{core::ErrorCode::io,
                              "Cannot inspect the selected disc folder"};
        }
        if (hasCueExtension(entry.path()) &&
            std::filesystem::is_symlink(status)) {
            throw core::Error{core::ErrorCode::unsupported,
                              "CUE file must be a regular file, not a link"};
        }
        if (std::filesystem::is_regular_file(status) &&
            hasCueExtension(entry.path())) {
            cue_paths.push_back(entry.path());
        }
        iterator.increment(error);
        if (error) {
            throw core::Error{core::ErrorCode::io,
                              "Cannot enumerate the selected disc folder"};
        }
    }

    if (cue_paths.empty()) {
        throw core::Error{core::ErrorCode::not_found,
                          "No top-level CUE file was found in the selected folder"};
    }
    if (cue_paths.size() != 1U) {
        throw core::Error{core::ErrorCode::unsupported,
                          "Expected exactly one top-level CUE file"};
    }

    std::error_code cue_metadata_error;
    const auto cue_status =
        std::filesystem::symlink_status(cue_paths.front(), cue_metadata_error);
    if (cue_metadata_error || std::filesystem::is_symlink(cue_status) ||
        !std::filesystem::is_regular_file(cue_status)) {
        throw core::Error{core::ErrorCode::unsupported,
                          "CUE file must be a regular file, not a link"};
    }

    const auto sheet = CueSheet::load(cue_paths.front());
    std::error_code metadata_error;
    const auto binary_status =
        std::filesystem::symlink_status(sheet.dataTrack().binary_path,
                                        metadata_error);
    if (metadata_error || std::filesystem::is_symlink(binary_status) ||
        !std::filesystem::is_regular_file(binary_status)) {
        throw core::Error{core::ErrorCode::unsupported,
                          "Track binary must be a regular file, not a link"};
    }
    const auto binary_size =
        std::filesystem::file_size(sheet.dataTrack().binary_path, metadata_error);
    if (metadata_error || binary_size == 0U ||
        binary_size % sheet.dataTrack().sectorSize() != 0U) {
        throw core::Error{core::ErrorCode::invalid_format,
                          "Track binary size does not contain complete sectors"};
    }
    const auto sector_count = binary_size / sheet.dataTrack().sectorSize();
    if (sheet.dataTrack().index_lba >= sector_count) {
        throw core::Error{core::ErrorCode::invalid_format,
                          "CUE INDEX is outside the track binary"};
    }
    const auto canonical_folder = checkedCanonical(folder_path, "disc folder");
    const auto canonical_cue = checkedCanonical(sheet.path(), "CUE file");
    const auto canonical_binary =
        checkedCanonical(sheet.dataTrack().binary_path, "track binary");
    if (!isWithin(canonical_folder, canonical_cue) ||
        !isWithin(canonical_folder, canonical_binary)) {
        throw core::Error{core::ErrorCode::unsupported,
                          "CUE and BIN must stay inside the selected folder"};
    }

    return CueBinPair{canonical_folder, canonical_cue, canonical_binary};
}

} // namespace sf::disc
