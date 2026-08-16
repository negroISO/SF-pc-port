#include "sf/core/error.hpp"
#include "sf/disc/disc_folder.hpp"

#include <chrono>
#include <array>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error{message};
    }
}

class TemporaryDirectory final {
public:
    TemporaryDirectory() {
        const auto nonce = std::chrono::steady_clock::now().time_since_epoch().count();
        path_ = std::filesystem::temp_directory_path() /
                ("sf-disc-folder-test-" + std::to_string(nonce));
        std::filesystem::create_directories(path_);
    }

    ~TemporaryDirectory() { std::filesystem::remove_all(path_); }

    [[nodiscard]] const std::filesystem::path& path() const noexcept {
        return path_;
    }

private:
    std::filesystem::path path_;
};

void writeBinary(const std::filesystem::path& path) {
    std::ofstream stream{path, std::ios::binary};
    std::array<std::byte, 2352U> sector{};
    sector.front() = std::byte{0x5a};
    stream.write(reinterpret_cast<const char*>(sector.data()),
                 static_cast<std::streamsize>(sector.size()));
}

void writeCue(const std::filesystem::path& path, std::string_view binary_name,
              std::string_view index = "00:00:00") {
    std::ofstream stream{path};
    stream << "FILE \"" << binary_name << "\" BINARY\n"
           << "  TRACK 01 MODE2/2352\n"
           << "    INDEX 01 " << index << "\n";
}

template <typename Function>
void requireThrows(Function&& function, const char* message) {
    try {
        function();
    } catch (const sf::core::Error&) {
        return;
    }
    require(false, message);
}

void testDiscPairIsDiscoveredWithoutCopying() {
    TemporaryDirectory directory;
    const auto binary = directory.path() / "Syphon Filter.bin";
    const auto cue = directory.path() / "Syphon Filter.CUE";
    writeBinary(binary);
    writeCue(cue, binary.filename().string());

    const auto pair = sf::disc::discoverCueBinPair(directory.path());
    require(pair.folder_path == std::filesystem::canonical(directory.path()),
            "disc folder was not canonicalized");
    require(pair.cue_path == std::filesystem::canonical(cue),
            "uppercase CUE extension was not discovered");
    require(pair.binary_path == std::filesystem::canonical(binary),
            "CUE companion BIN was not resolved in place");
}

void testFolderRequiresExactlyOneCue() {
    TemporaryDirectory directory;
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "folder without a CUE was accepted");

    const auto binary = directory.path() / "disc.bin";
    writeBinary(binary);
    writeCue(directory.path() / "one.cue", binary.filename().string());
    writeCue(directory.path() / "two.cue", binary.filename().string());
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "folder with multiple CUE files was accepted");
}

void testMissingAndEscapingBinsAreRejected() {
    TemporaryDirectory directory;
    writeCue(directory.path() / "missing.cue", "missing.bin");
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "missing BIN was accepted");

    std::filesystem::remove(directory.path() / "missing.cue");
    const auto outside_binary = directory.path().parent_path() /
                                (directory.path().filename().string() + ".bin");
    writeBinary(outside_binary);
    writeCue(directory.path() / "escape.cue",
             (std::filesystem::path{".."} / outside_binary.filename()).string());
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "CUE reference outside the selected folder was accepted");
    std::filesystem::remove(outside_binary);
}

void testInvalidCompanionMetadataIsRejected() {
    TemporaryDirectory directory;
    const auto binary = directory.path() / "disc.bin";
    {
        std::ofstream stream{binary, std::ios::binary};
        stream.put('x');
    }
    writeCue(directory.path() / "disc.cue", binary.filename().string());
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "partial track sector was accepted");

    writeBinary(binary);
    writeCue(directory.path() / "disc.cue", "DISC.BIN");
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "case-mismatched companion filename was accepted");

    writeCue(directory.path() / "disc.cue", binary.filename().string(),
             "00:00:01");
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "CUE INDEX outside the track binary was accepted");
}

void testSymlinkCompanionIsRejected() {
    TemporaryDirectory directory;
    const auto target = directory.path() / "target.bin";
    const auto link = directory.path() / "disc.bin";
    writeBinary(target);
    std::error_code error;
    std::filesystem::create_symlink(target.filename(), link, error);
    require(!error, "temporary filesystem cannot create the symlink fixture");
    writeCue(directory.path() / "disc.cue", link.filename().string());
    requireThrows(
        [&] { static_cast<void>(sf::disc::discoverCueBinPair(directory.path())); },
        "symlink track binary was accepted");
}

void testSymlinkCueIsRejectedBeforeParsing() {
    TemporaryDirectory directory;
    const auto binary = directory.path() / "disc.bin";
    const auto cue_target = directory.path() / "cue-target.txt";
    const auto cue_link = directory.path() / "disc.cue";
    writeBinary(binary);
    writeCue(cue_target, binary.filename().string());

    std::error_code error;
    std::filesystem::create_symlink(cue_target.filename(), cue_link, error);
    require(!error, "temporary filesystem cannot create the CUE symlink fixture");

    try {
        static_cast<void>(sf::disc::discoverCueBinPair(directory.path()));
    } catch (const sf::core::Error& cue_error) {
        require(std::string{cue_error.what()}.find("CUE file must be a regular file") !=
                    std::string::npos,
                "CUE symlink was rejected only after parsing its target");
        return;
    }
    require(false, "symlink CUE was accepted");
}

} // namespace

int main() {
    try {
        testDiscPairIsDiscoveredWithoutCopying();
        testFolderRequiresExactlyOneCue();
        testMissingAndEscapingBinsAreRejected();
        testInvalidCompanionMetadataIsRejected();
        testSymlinkCompanionIsRejected();
        testSymlinkCueIsRejectedBeforeParsing();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
