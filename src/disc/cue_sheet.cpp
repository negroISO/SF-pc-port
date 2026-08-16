#include "sf/disc/cue_sheet.hpp"

#include "sf/core/error.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <optional>
#include <regex>
#include <string>
#include <system_error>

namespace sf::disc {
namespace {

std::string uppercase(std::string value) {
    std::ranges::transform(value, value.begin(), [](unsigned char character) {
        return static_cast<char>(std::toupper(character));
    });
    return value;
}

std::uint32_t parseTimestamp(const std::smatch& match) {
    const auto minutes = static_cast<std::uint32_t>(std::stoul(match[1].str()));
    const auto seconds = static_cast<std::uint32_t>(std::stoul(match[2].str()));
    const auto frames = static_cast<std::uint32_t>(std::stoul(match[3].str()));
    if (seconds >= 60 || frames >= 75) {
        throw core::Error{core::ErrorCode::invalid_format, "Invalid CUE INDEX timestamp"};
    }
    return minutes * 60U * 75U + seconds * 75U + frames;
}

} // namespace

std::uint32_t DataTrack::sectorSize() const noexcept {
    return mode == TrackMode::mode1_2048 ? 2048U : 2352U;
}

std::uint32_t DataTrack::userDataOffset() const noexcept {
    switch (mode) {
    case TrackMode::mode1_2048:
        return 0;
    case TrackMode::mode1_2352:
        return 16;
    case TrackMode::mode2_2352:
        return 24;
    }
    return 0;
}

CueSheet CueSheet::load(const std::filesystem::path& cue_path) {
    constexpr std::uintmax_t maximum_cue_size = 1024U * 1024U;
    std::error_code size_error;
    const auto cue_size = std::filesystem::file_size(cue_path, size_error);
    if (size_error) {
        throw core::Error{core::ErrorCode::io, "Cannot inspect CUE file"};
    }
    if (cue_size > maximum_cue_size) {
        throw core::Error{core::ErrorCode::unsupported,
                          "CUE file exceeds the 1 MiB safety limit"};
    }

    std::ifstream stream{cue_path};
    if (!stream) {
        throw core::Error{core::ErrorCode::io, "Cannot open CUE file: " + cue_path.string()};
    }

    const std::regex file_pattern{R"(^\s*FILE\s+\"([^\"]+)\"\s+BINARY\s*$)", std::regex::icase};
    const std::regex track_pattern{R"(^\s*TRACK\s+([0-9]+)\s+([^\s]+)\s*$)", std::regex::icase};
    const std::regex index_pattern{R"(^\s*INDEX\s+01\s+([0-9]+):([0-9]+):([0-9]+)\s*$)", std::regex::icase};

    std::optional<std::filesystem::path> binary_path;
    std::optional<TrackMode> mode;
    std::optional<std::uint32_t> index_lba;
    std::size_t data_track_count = 0;
    std::string line;
    while (std::getline(stream, line)) {
        std::smatch match;
        if (std::regex_match(line, match, file_pattern)) {
            if (binary_path) {
                throw core::Error{core::ErrorCode::unsupported, "Multi-file CUE sheets are not supported"};
            }
            const auto reference = std::filesystem::path{match[1].str()};
            if (reference.empty() || reference.is_absolute() ||
                reference.has_parent_path()) {
                throw core::Error{
                    core::ErrorCode::unsupported,
                    "CUE track binary must be a filename beside the CUE"};
            }
            binary_path = cue_path.parent_path() / reference;
        } else if (std::regex_match(line, match, track_pattern)) {
            ++data_track_count;
            const auto track_mode = uppercase(match[2].str());
            if (track_mode == "MODE1/2048") {
                mode = TrackMode::mode1_2048;
            } else if (track_mode == "MODE1/2352") {
                mode = TrackMode::mode1_2352;
            } else if (track_mode == "MODE2/2352") {
                mode = TrackMode::mode2_2352;
            } else {
                throw core::Error{core::ErrorCode::unsupported, "Unsupported CUE track mode: " + track_mode};
            }
        } else if (std::regex_match(line, match, index_pattern)) {
            index_lba = parseTimestamp(match);
        }
    }

    if (!binary_path || !mode || !index_lba || data_track_count != 1) {
        throw core::Error{core::ErrorCode::invalid_format, "Expected one indexed data track in CUE file"};
    }
    if (!std::filesystem::is_regular_file(*binary_path)) {
        throw core::Error{core::ErrorCode::not_found, "Track binary was not found: " + binary_path->string()};
    }

    // A case-insensitive host can otherwise accept a CUE that fails when the
    // same folder is moved to a case-sensitive Files provider.
    auto exact_filename_found = false;
    std::error_code directory_error;
    std::filesystem::directory_iterator iterator{cue_path.parent_path(),
                                                  directory_error};
    const std::filesystem::directory_iterator end;
    while (!directory_error && iterator != end) {
        exact_filename_found =
            exact_filename_found ||
            iterator->path().filename().native() == binary_path->filename().native();
        iterator.increment(directory_error);
    }
    if (directory_error || !exact_filename_found) {
        throw core::Error{core::ErrorCode::not_found,
                          "CUE track binary filename does not match exactly"};
    }

    CueSheet result;
    result.path_ = cue_path;
    result.data_track_ = DataTrack{*binary_path, *mode, *index_lba};
    return result;
}

} // namespace sf::disc
