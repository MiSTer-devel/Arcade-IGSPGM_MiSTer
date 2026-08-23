#ifndef MRA_LOADER_H
#define MRA_LOADER_H

#include <string>
#include <vector>
#include <cstdint>
#include "third_party/miniz.h"

/**
 * MRA (MiSTer ROM Archive) loader
 * Parses MRA XML files and assembles ROM data from various sources
 */
class MRALoader
{
  public:
    /**
     * Load an MRA file and assemble the ROM data
     * @param mraPath Path to the .mra file
     * @param romData Output vector to store the assembled ROM data
     * @param address Output DDR address to load the data at (0 if not used)
     * @return true if successful, false on error
     */
    bool Load(const std::string &mraPath, std::vector<uint8_t> &romData, uint32_t &address);

    /**
     * Get the last error message
     * @return Error message from the last failed operation
     */
    const std::string &GetLastError() const
    {
        return mLastError;
    }

    uint8_t GetRegionDefault() const
    {
        return mRegionDefault;
    }

  private:
    std::string mLastError;
    uint8_t mRegionDefault = 0xff;

    /**
     * Parse hex string into bytes
     * @param hexStr Hex string (e.g., "1b 00" or "1b00")
     * @param output Vector to append bytes to
     * @return true if successful
     */
    bool ParseHexString(const std::string &hexStr, std::vector<uint8_t> &output);

    /**
     * Apply map attribute to data (e.g., "01" to take odd bytes)
     * @param data Input/output data to transform
     * @param mapStr Map string
     * @return true if successful
     */
    bool ApplyMap(std::vector<uint8_t> &data, const std::string &mapStr);

    /**
     * Calculate CRC32 of data
     * @param data Data to checksum
     * @return CRC32 value
     */
    uint32_t CalculateCRC32(const std::vector<uint8_t> &data);
};

#endif // MRA_LOADER_H
