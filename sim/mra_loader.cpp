#include "mra_loader.h"
#include "file_search.h"
#include "third_party/miniz.h"
#include "third_party/pugixml.hpp"
#include <filesystem>
#include <fstream>
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <cctype>

bool MRALoader::Load(const std::string &mraPath, std::vector<uint8_t> &romData, uint32_t &address)
{
    romData.clear();
    mLastError.clear();
    mRegionDefault = 0xff;

    // Save current search paths state
    auto savedPaths = gFileSearch.SaveSearchPaths();

    // Load and parse the MRA XML file
    pugi::xml_document doc;
    pugi::xml_parse_result result = doc.load_file(mraPath.c_str());

    if (!result)
    {
        mLastError = "Failed to parse MRA file: " + std::string(result.description());
        gFileSearch.RestoreSearchPaths(savedPaths);
        return false;
    }

    const std::string switchDefault = doc.child("misterromdescription").child("switches").attribute("default").as_string("");
    if (switchDefault.size() >= 4)
    {
        try
        {
            mRegionDefault = static_cast<uint8_t>((std::stoul(switchDefault, nullptr, 16) >> 8) & 0xff);
        }
        catch (...)
        {
            mRegionDefault = 0xff;
        }
    }

    // Add the MRA directory to search paths
    std::filesystem::path mraDir = std::filesystem::path(mraPath).parent_path();
    if (!mraDir.empty())
    {
        gFileSearch.AddSearchPath(mraDir.string());
    }

    // Find the rom element with index="0" (or no index attribute)
    pugi::xml_node romNode;
    for (auto rom : doc.child("misterromdescription").children("rom"))
    {
        int index = rom.attribute("index").as_int(0);
        if (index == 0)
        {
            romNode = rom;
            break;
        }
    }

    if (!romNode)
    {
        mLastError = "No ROM element with index 0 found";
        gFileSearch.RestoreSearchPaths(savedPaths);
        return false;
    }

    std::string addressStr = romNode.attribute("address").as_string("");
    try
    {
        address = std::stoul(addressStr, nullptr, 16);
    }
    catch (...)
    {
        address = 0;
    }

    // Get the zip file path(s) if specified and add them to search paths
    std::string zipAttr = romNode.attribute("zip").as_string("");
    if (!zipAttr.empty())
    {
        // Split zip attribute by | character to support multiple zip files
        std::vector<std::string> zipPaths;
        std::stringstream ss(zipAttr);
        std::string zipPath;

        while (std::getline(ss, zipPath, '|'))
        {
            // Trim whitespace
            zipPath.erase(0, zipPath.find_first_not_of(" \t"));
            zipPath.erase(zipPath.find_last_not_of(" \t") + 1);
            if (!zipPath.empty())
            {
                zipPaths.push_back(zipPath);
            }
        }

        // Try to find and add each zip file to search paths
        bool foundAnyZip = false;
        for (const std::string &zip : zipPaths)
        {
            std::string actualZipPath = gFileSearch.FindFilePath(zip);
            if (!actualZipPath.empty())
            {
                // Found the zip file, add it to search paths
                gFileSearch.AddSearchPath(actualZipPath);
                foundAnyZip = true;
            }
        }

        if (!foundAnyZip)
        {
            mLastError = "Could not find any ZIP files from: " + zipAttr;
            gFileSearch.RestoreSearchPaths(savedPaths);
            return false;
        }
    }

    // Process each part in order
    for (auto child : romNode.children())
    {
        std::string nodeName = child.name();

        if (nodeName == "part")
        {
            // Get part attributes
            std::string fileName = child.attribute("name").as_string("");
            std::string crcStr = child.attribute("crc").as_string("");
            int repeat = child.attribute("repeat").as_int(1);
            int offset = child.attribute("offset").as_int(0);
            int length = child.attribute("length").as_int(-1);
            std::string mapStr = child.attribute("map").as_string("");

            std::vector<uint8_t> partData;

            if (!fileName.empty())
            {
                // Parse CRC if provided
                uint32_t crc32Value = 0;
                if (!crcStr.empty())
                {
                    try
                    {
                        crc32Value = std::stoul(crcStr, nullptr, 16);
                    }
                    catch (...)
                    {
                        // Invalid CRC, ignore it
                        crc32Value = 0;
                    }
                }

                // Load file from zip or filesystem using FileSearch
                bool loaded = false;
                if (crc32Value != 0)
                {
                    // Try CRC lookup first
                    loaded = gFileSearch.LoadFileByCRC(crc32Value, partData);
                }
                if (!loaded)
                {
                    // Fallback to filename lookup
                    loaded = gFileSearch.LoadFile(fileName, partData);
                }

                if (!loaded)
                {
                    mLastError = "Failed to load file: " + fileName;
                    gFileSearch.RestoreSearchPaths(savedPaths);
                    return false;
                }

                // Apply offset and length
                if (offset > 0 || length >= 0)
                {
                    if (offset >= partData.size())
                    {
                        mLastError = "Offset exceeds file size for: " + fileName;
                        gFileSearch.RestoreSearchPaths(savedPaths);
                        return false;
                    }

                    size_t endPos = partData.size();
                    if (length >= 0)
                    {
                        endPos = std::min(endPos, (size_t)(offset + length));
                    }

                    partData = std::vector<uint8_t>(partData.begin() + offset, partData.begin() + endPos);
                }

                // Apply map if specified
                if (!mapStr.empty())
                {
                    if (!ApplyMap(partData, mapStr))
                    {
                        mLastError = "Failed to apply map: " + mapStr;
                        gFileSearch.RestoreSearchPaths(savedPaths);
                        return false;
                    }
                }
            }
            else
            {
                // Parse hex data from text content
                std::string hexData = child.child_value();
                if (!hexData.empty())
                {
                    if (!ParseHexString(hexData, partData))
                    {
                        mLastError = "Failed to parse hex data";
                        gFileSearch.RestoreSearchPaths(savedPaths);
                        return false;
                    }
                }
            }

            // Verify CRC if specified
            if (!crcStr.empty() && !partData.empty())
            {
                uint32_t expectedCrc = std::stoul(crcStr, nullptr, 16);
                uint32_t actualCrc = CalculateCRC32(partData);
                if (expectedCrc != actualCrc)
                {
                    mLastError = "CRC mismatch for " + fileName + ": expected " + crcStr + ", got " + std::to_string(actualCrc);
                    // Note: Just warning, not failing
                    printf("Warning: %s\n", mLastError.c_str());
                }
            }

            // Apply repeat
            for (int r = 0; r < repeat; r++)
            {
                romData.insert(romData.end(), partData.begin(), partData.end());
            }
        }
        else if (nodeName == "interleave")
        {
            // Handle interleaved parts
            int outputWidth = child.attribute("output").as_int(8);
            if (outputWidth != 8 && outputWidth != 16 && outputWidth != 32)
            {
                mLastError = "Invalid interleave output width: " + std::to_string(outputWidth);
                gFileSearch.RestoreSearchPaths(savedPaths);
                return false;
            }

            std::vector<std::vector<uint8_t>> interleaveParts;
            std::vector<std::string> maps;

            // Load all interleaved parts
            for (auto part : child.children("part"))
            {
                std::string fileName = part.attribute("name").as_string("");
                std::string mapStr = part.attribute("map").as_string("");
                std::string crcStr = part.attribute("crc").as_string("");

                // Parse CRC if provided
                uint32_t crc32Value = 0;
                if (!crcStr.empty())
                {
                    try
                    {
                        crc32Value = std::stoul(crcStr, nullptr, 16);
                    }
                    catch (...)
                    {
                        crc32Value = 0;
                    }
                }

                std::vector<uint8_t> partData;

                if (!fileName.empty())
                {
                    // Load file using FileSearch
                    bool loaded = false;
                    if (crc32Value != 0)
                    {
                        // Try CRC lookup first
                        loaded = gFileSearch.LoadFileByCRC(crc32Value, partData);
                    }
                    if (!loaded)
                    {
                        // Fallback to filename lookup
                        loaded = gFileSearch.LoadFile(fileName, partData);
                    }

                    if (!loaded)
                    {
                        mLastError = "Failed to load interleave file: " + fileName;
                        gFileSearch.RestoreSearchPaths(savedPaths);
                        return false;
                    }
                }
                else
                {
                    // Parse hex data from text content
                    std::string hexData = part.child_value();
                    if (!hexData.empty())
                    {
                        if (!ParseHexString(hexData, partData))
                        {
                            mLastError = "Failed to parse hex data in interleave";
                            gFileSearch.RestoreSearchPaths(savedPaths);
                            return false;
                        }
                    }
                }

                // Verify CRC if specified
                if (!crcStr.empty())
                {
                    uint32_t expectedCrc = std::stoul(crcStr, nullptr, 16);
                    uint32_t actualCrc = CalculateCRC32(partData);
                    if (expectedCrc != actualCrc)
                    {
                        printf("Warning: CRC mismatch for %s\n", fileName.c_str());
                    }
                }

                interleaveParts.push_back(partData);
                maps.push_back(mapStr);
            }

            // Perform interleaving: combine multiple parts into wider output
            if (interleaveParts.empty())
            {
                mLastError = "No parts in interleave section";
                gFileSearch.RestoreSearchPaths(savedPaths);
                return false;
            }

            size_t maxSize = 0;
            for (const auto &part : interleaveParts)
            {
                maxSize = std::max(maxSize, part.size());
            }

            int bytesPerUnit = outputWidth / 8; // bytes per output unit

            // Create temporary storage for each output position
            std::vector<std::vector<uint8_t>> outputSlots(bytesPerUnit);

            // Process each part and place bytes according to map
            for (size_t partIdx = 0; partIdx < interleaveParts.size(); partIdx++)
            {
                const auto &part = interleaveParts[partIdx];
                const std::string &mapStr = maps[partIdx];

                // Convert map string to determine byte placement
                // For output="16": map="10" means high byte, map="01" means low byte
                std::vector<int> targetSlots;

                if (mapStr.empty())
                {
                    // No map specified, place in order
                    targetSlots.push_back(partIdx % bytesPerUnit);
                }
                else
                {
                    // Parse map string to determine byte placement
                    // For 16-bit: "10" means high byte, "01" means low byte
                    // For 32-bit: "1200" means bytes 0,1 and "0012" means bytes 2,3

                    if (mapStr.length() == bytesPerUnit)
                    {
                        // Multi-byte pattern: each position corresponds to a byte lane
                        // Look for positions where this part's data should go
                        for (size_t i = 0; i < mapStr.length(); i++)
                        {
                            char c = mapStr[i];
                            // For patterns like "1200", part 0 data goes where we see '1' or '2'
                            // For patterns like "0012", part 1 data goes where we see '1' or '2'
                            if ((c == '1') || (c == '2'))
                            {
                                int slot = mapStr.length() - 1 - i;
                                if (slot >= 0 && slot < bytesPerUnit)
                                {
                                    targetSlots.push_back(slot);
                                }
                            }
                        }
                    }
                    else
                    {
                        // Legacy binary pattern: look for '1' positions
                        for (size_t i = 0; i < mapStr.length(); i++)
                        {
                            char c = mapStr[i];
                            if (c == '1')
                            {
                                int slot = mapStr.length() - 1 - i;
                                if (slot >= 0 && slot < bytesPerUnit)
                                {
                                    targetSlots.push_back(slot);
                                }
                            }
                        }
                    }
                }

                // Place bytes from this part into target slots
                if (targetSlots.size() == 1)
                {
                    // Single target slot: place all bytes there
                    for (size_t byteIdx = 0; byteIdx < part.size(); byteIdx++)
                    {
                        outputSlots[targetSlots[0]].push_back(part[byteIdx]);
                    }
                }
                else if (targetSlots.size() > 1)
                {
                    // Multiple target slots: distribute bytes sequentially
                    for (size_t byteIdx = 0; byteIdx < part.size(); byteIdx++)
                    {
                        int slot = targetSlots[byteIdx % targetSlots.size()];
                        outputSlots[slot].push_back(part[byteIdx]);
                    }
                }
            }

            // Interleave the output: take one byte from each slot in order
            size_t maxSlotSize = 0;
            for (const auto &slot : outputSlots)
            {
                maxSlotSize = std::max(maxSlotSize, slot.size());
            }

            for (size_t unitIdx = 0; unitIdx < maxSlotSize; unitIdx++)
            {
                for (int slot = 0; slot < bytesPerUnit; slot++)
                {
                    if (unitIdx < outputSlots[slot].size())
                    {
                        romData.push_back(outputSlots[slot][unitIdx]);
                    }
                    else
                    {
                        romData.push_back(0); // Pad with zeros
                    }
                }
            }
        }
    }

    // Restore search paths
    gFileSearch.RestoreSearchPaths(savedPaths);
    return true;
}

bool MRALoader::ParseHexString(const std::string &hexStr, std::vector<uint8_t> &output)
{
    std::string cleaned;

    // Remove whitespace and convert to uppercase
    for (char c : hexStr)
    {
        if (!std::isspace(c))
        {
            cleaned += std::toupper(c);
        }
    }

    // Must have even number of hex digits
    if (cleaned.length() % 2 != 0)
    {
        return false;
    }

    // Convert hex pairs to bytes
    for (size_t i = 0; i < cleaned.length(); i += 2)
    {
        std::string byteStr = cleaned.substr(i, 2);
        try
        {
            uint8_t byte = std::stoul(byteStr, nullptr, 16);
            output.push_back(byte);
        }
        catch (...)
        {
            return false;
        }
    }

    return true;
}

bool MRALoader::ApplyMap(std::vector<uint8_t> &data, const std::string &mapStr) // NOLINT(readability-identifier-naming)
{
    // Map string like "0001" means take every 4th byte starting at offset 3
    // Map string like "01" means take odd bytes

    if (mapStr.empty())
    {
        return true;
    }

    std::vector<uint8_t> result;
    size_t mapLen = mapStr.length();

    for (size_t i = 0; i < data.size(); i++)
    {
        char mapChar = mapStr[i % mapLen];
        if (mapChar == '1')
        {
            result.push_back(data[i]);
        }
    }

    data = std::move(result);
    return true;
}

uint32_t MRALoader::CalculateCRC32(const std::vector<uint8_t> &data)
{
    return mz_crc32(MZ_CRC32_INIT, data.data(), data.size());
}
