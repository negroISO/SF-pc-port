#pragma once

#include <filesystem>

namespace sf::disc {

// A user-managed folder selected through a platform file picker. The CUE and
// its referenced BIN stay in that folder; the application never copies them
// into its private container.
struct CueBinPair {
    std::filesystem::path folder_path;
    std::filesystem::path cue_path;
    std::filesystem::path binary_path;
};

// Finds exactly one top-level CUE, validates the existing single-track parser,
// and rejects CUE references that escape the selected folder.
[[nodiscard]] CueBinPair
discoverCueBinPair(const std::filesystem::path& folder_path);

} // namespace sf::disc
