#include "sim_protocol.h"

#include <cctype>
#include <cstdint>
#include <iomanip>
#include <limits>
#include <map>
#include <sstream>
#include <utility>
#include <vector>

namespace
{
class JsonValue
{
  public:
    enum class Type
    {
        NULL_VALUE,
        BOOL,
        NUMBER,
        STRING,
        ARRAY,
        OBJECT
    };

    Type mType = Type::NULL_VALUE;
    bool mBool = false;
    uint64_t mNumber = 0;
    int64_t mSignedNumber = 0;
    bool mNumberSigned = false;
    std::string mString;
    std::vector<JsonValue> mArray;
    std::map<std::string, JsonValue> mObject;

    static JsonValue Null()
    {
        return {};
    }

    static JsonValue Bool(bool value)
    {
        JsonValue json;
        json.mType = Type::BOOL;
        json.mBool = value;
        return json;
    }

    static JsonValue Number(uint64_t value)
    {
        JsonValue json;
        json.mType = Type::NUMBER;
        json.mNumber = value;
        json.mNumberSigned = false;
        return json;
    }

    static JsonValue SignedNumber(int64_t value)
    {
        JsonValue json;
        json.mType = Type::NUMBER;
        json.mSignedNumber = value;
        json.mNumberSigned = true;
        return json;
    }

    static JsonValue String(const std::string &value)
    {
        JsonValue json;
        json.mType = Type::STRING;
        json.mString = value;
        return json;
    }

    static JsonValue Array(std::vector<JsonValue> value)
    {
        JsonValue json;
        json.mType = Type::ARRAY;
        json.mArray = std::move(value);
        return json;
    }

    static JsonValue Object(std::map<std::string, JsonValue> value)
    {
        JsonValue json;
        json.mType = Type::OBJECT;
        json.mObject = std::move(value);
        return json;
    }

    bool IsObject() const { return mType == Type::OBJECT; }
    bool IsArray() const { return mType == Type::ARRAY; }
    bool IsString() const { return mType == Type::STRING; }
    bool IsNumber() const { return mType == Type::NUMBER; }
    bool IsBool() const { return mType == Type::BOOL; }
};

class JsonParser
{
  public:
    explicit JsonParser(const std::string &input) : mInput(input) {}

    bool Parse(JsonValue &value, std::string &error)
    {
        SkipWhitespace();
        if (!ParseValue(value))
        {
            error = mError;
            return false;
        }
        SkipWhitespace();
        if (mPos != mInput.size())
        {
            error = "Trailing data after JSON value";
            return false;
        }
        return true;
    }

  private:
    const std::string &mInput;
    size_t mPos = 0;
    std::string mError;

    void SkipWhitespace()
    {
        while (mPos < mInput.size() && std::isspace(static_cast<unsigned char>(mInput[mPos])))
            mPos++;
    }

    bool Peek(char &c)
    {
        if (mPos >= mInput.size())
        {
            mError = "Unexpected end of input";
            return false;
        }
        c = mInput[mPos];
        return true;
    }

    bool Consume(char &c)
    {
        if (!Peek(c))
            return false;
        mPos++;
        return true;
    }

    bool Expect(char expected)
    {
        char actual;
        if (!Consume(actual))
            return false;
        if (actual != expected)
        {
            mError = "Unexpected JSON token";
            return false;
        }
        return true;
    }

    bool ParseValue(JsonValue &value)
    {
        SkipWhitespace();
        char c;
        if (!Peek(c))
            return false;
        if (c == '{')
            return ParseObject(value);
        if (c == '[')
            return ParseArray(value);
        if (c == '"')
        {
            std::string stringValue;
            if (!ParseString(stringValue))
                return false;
            value = JsonValue::String(stringValue);
            return true;
        }
        if (c == 't' || c == 'f')
        {
            bool boolValue = false;
            if (!ParseBool(boolValue))
                return false;
            value = JsonValue::Bool(boolValue);
            return true;
        }
        if (c == 'n')
        {
            if (!ParseNull())
                return false;
            value = JsonValue::Null();
            return true;
        }
        if (std::isdigit(static_cast<unsigned char>(c)))
        {
            uint64_t numberValue = 0;
            if (!ParseNumber(numberValue))
                return false;
            value = JsonValue::Number(numberValue);
            return true;
        }
        if (c == '-')
        {
            mError = "Negative numbers are not supported in this protocol";
            return false;
        }

        mError = "Invalid JSON value";
        return false;
    }

    bool ParseObject(JsonValue &value)
    {
        if (!Expect('{'))
            return false;
        SkipWhitespace();

        std::map<std::string, JsonValue> object;
        char c;
        if (!Peek(c))
            return false;
        if (c == '}')
        {
            if (!Consume(c))
                return false;
            value = JsonValue::Object(std::move(object));
            return true;
        }

        while (true)
        {
            std::string key;
            if (!ParseString(key))
                return false;
            SkipWhitespace();
            if (!Expect(':'))
                return false;
            SkipWhitespace();

            JsonValue childValue;
            if (!ParseValue(childValue))
                return false;
            object[key] = childValue;

            SkipWhitespace();
            if (!Consume(c))
                return false;
            if (c == '}')
                break;
            if (c != ',')
            {
                mError = "Expected ',' or '}' in object";
                return false;
            }
            SkipWhitespace();
        }

        value = JsonValue::Object(std::move(object));
        return true;
    }

    bool ParseArray(JsonValue &value)
    {
        if (!Expect('['))
            return false;
        SkipWhitespace();

        std::vector<JsonValue> array;
        char c;
        if (!Peek(c))
            return false;
        if (c == ']')
        {
            if (!Consume(c))
                return false;
            value = JsonValue::Array(std::move(array));
            return true;
        }

        while (true)
        {
            JsonValue childValue;
            if (!ParseValue(childValue))
                return false;
            array.push_back(childValue);

            SkipWhitespace();
            if (!Consume(c))
                return false;
            if (c == ']')
                break;
            if (c != ',')
            {
                mError = "Expected ',' or ']' in array";
                return false;
            }
            SkipWhitespace();
        }

        value = JsonValue::Array(std::move(array));
        return true;
    }

    bool ParseString(std::string &result)
    {
        if (!Expect('"'))
            return false;
        result.clear();

        while (true)
        {
            char c;
            if (!Consume(c))
                return false;
            if (c == '"')
                break;
            if (c == '\\')
            {
                char escaped;
                if (!Consume(escaped))
                    return false;
                switch (escaped)
                {
                case '"': result.push_back('"'); break;
                case '\\': result.push_back('\\'); break;
                case '/': result.push_back('/'); break;
                case 'b': result.push_back('\b'); break;
                case 'f': result.push_back('\f'); break;
                case 'n': result.push_back('\n'); break;
                case 'r': result.push_back('\r'); break;
                case 't': result.push_back('\t'); break;
                default:
                    mError = "Unsupported string escape";
                    return false;
                }
            }
            else
            {
                result.push_back(c);
            }
        }

        return true;
    }

    bool ParseBool(bool &value)
    {
        if (mInput.compare(mPos, 4, "true") == 0)
        {
            mPos += 4;
            value = true;
            return true;
        }
        if (mInput.compare(mPos, 5, "false") == 0)
        {
            mPos += 5;
            value = false;
            return true;
        }
        mError = "Invalid boolean value";
        return false;
    }

    bool ParseNull()
    {
        if (mInput.compare(mPos, 4, "null") != 0)
        {
            mError = "Invalid null value";
            return false;
        }
        mPos += 4;
        return true;
    }

    bool ParseNumber(uint64_t &value)
    {
        size_t start = mPos;
        while (mPos < mInput.size() && std::isdigit(static_cast<unsigned char>(mInput[mPos])))
            mPos++;

        if (start == mPos)
        {
            mError = "Invalid number";
            return false;
        }

        uint64_t parsed = 0;
        for (size_t i = start; i < mPos; i++)
        {
            uint64_t digit = static_cast<uint64_t>(mInput[i] - '0');
            if (parsed > (std::numeric_limits<uint64_t>::max() - digit) / 10)
            {
                mError = "Number out of range";
                return false;
            }
            parsed = parsed * 10 + digit;
        }

        value = parsed;
        return true;
    }
};

std::string EscapeJsonString(const std::string &value)
{
    std::ostringstream out;
    for (char c : value)
    {
        switch (c)
        {
        case '"': out << "\\\""; break;
        case '\\': out << "\\\\"; break;
        case '\b': out << "\\b"; break;
        case '\f': out << "\\f"; break;
        case '\n': out << "\\n"; break;
        case '\r': out << "\\r"; break;
        case '\t': out << "\\t"; break;
        default: out << c; break;
        }
    }
    return out.str();
}

std::string SerializeJson(const JsonValue &value)
{
    std::ostringstream out;
    switch (value.mType)
    {
    case JsonValue::Type::NULL_VALUE:
        out << "null";
        break;
    case JsonValue::Type::BOOL:
        out << (value.mBool ? "true" : "false");
        break;
    case JsonValue::Type::NUMBER:
        if (value.mNumberSigned)
            out << value.mSignedNumber;
        else
            out << value.mNumber;
        break;
    case JsonValue::Type::STRING:
        out << '"' << EscapeJsonString(value.mString) << '"';
        break;
    case JsonValue::Type::ARRAY:
        out << '[';
        for (size_t i = 0; i < value.mArray.size(); i++)
        {
            if (i > 0)
                out << ',';
            out << SerializeJson(value.mArray[i]);
        }
        out << ']';
        break;
    case JsonValue::Type::OBJECT:
        out << '{';
        {
            bool first = true;
            for (const auto &entry : value.mObject)
            {
                if (!first)
                    out << ',';
                first = false;
                out << '"' << EscapeJsonString(entry.first) << '"' << ':' << SerializeJson(entry.second);
            }
        }
        out << '}';
        break;
    }
    return out.str();
}

bool RequireNumber(const JsonValue &value, const std::string &name, uint64_t &out, std::string &error)
{
    if (!value.IsNumber())
    {
        error = "Expected numeric field: " + name;
        return false;
    }
    out = value.mNumber;
    return true;
}

bool RequireBool(const JsonValue &value, const std::string &name, bool &out, std::string &error)
{
    if (!value.IsBool())
    {
        error = "Expected boolean field: " + name;
        return false;
    }
    out = value.mBool;
    return true;
}

bool RequireString(const JsonValue &value, const std::string &name, std::string &out, std::string &error)
{
    if (!value.IsString())
    {
        error = "Expected string field: " + name;
        return false;
    }
    out = value.mString;
    return true;
}

const JsonValue *FindObjectField(const JsonValue &object, const std::string &name)
{
    if (!object.IsObject())
        return nullptr;
    auto it = object.mObject.find(name);
    if (it == object.mObject.end())
        return nullptr;
    return &it->second;
}

bool RequireObjectField(const JsonValue &object, const std::string &name, const JsonValue *&out, std::string &error)
{
    if (!object.IsObject())
    {
        error = "Expected object";
        return false;
    }
    out = FindObjectField(object, name);
    if (!out)
    {
        error = "Missing field: " + name;
        return false;
    }
    return true;
}

std::string BytesToHex(const std::vector<uint8_t> &data)
{
    std::ostringstream out;
    out << std::hex << std::setfill('0');
    for (uint8_t byte : data)
        out << std::setw(2) << static_cast<int>(byte);
    return out.str();
}

bool HexToBytes(const std::string &hex, std::vector<uint8_t> &data, std::string &error)
{
    if ((hex.size() & 1U) != 0)
    {
        error = "Hex string must have even length";
        return false;
    }

    data.clear();
    data.reserve(hex.size() / 2);
    for (size_t i = 0; i < hex.size(); i += 2)
    {
        unsigned int byte = 0;
        std::stringstream ss;
        ss << std::hex << hex.substr(i, 2);
        ss >> byte;
        if (ss.fail())
        {
            error = "Invalid hex data";
            return false;
        }
        data.push_back(static_cast<uint8_t>(byte));
    }
    return true;
}

std::string RunStopReasonString(RunStopReason reason)
{
    switch (reason)
    {
    case RunStopReason::COMPLETED: return "completed";
    case RunStopReason::CONDITION_MET: return "condition_met";
    case RunStopReason::WATCHPOINT_HIT: return "watchpoint_hit";
    case RunStopReason::TIMEOUT: return "timeout";
    case RunStopReason::ERROR: return "error";
    }
    return "error";
}

bool ParseCondition(const JsonValue &json, Condition &condition, std::string &error)
{
    const JsonValue *typeField = nullptr;
    std::string type;
    if (!RequireObjectField(json, "type", typeField, error) || !RequireString(*typeField, "type", type, error))
        return false;

    if (type == "signal_equals")
        condition.mType = Condition::Type::SIGNAL_EQUALS;
    else if (type == "signal_not_equals")
        condition.mType = Condition::Type::SIGNAL_NOT_EQUALS;
    else if (type == "signal_less_than")
        condition.mType = Condition::Type::SIGNAL_LESS_THAN;
    else if (type == "signal_less_equal")
        condition.mType = Condition::Type::SIGNAL_LESS_EQUAL;
    else if (type == "signal_greater_than")
        condition.mType = Condition::Type::SIGNAL_GREATER_THAN;
    else if (type == "signal_greater_equal")
        condition.mType = Condition::Type::SIGNAL_GREATER_EQUAL;
    else if (type == "cpu_pc_equals")
        condition.mType = Condition::Type::CPU_PC_EQUALS;
    else if (type == "cpu_pc_in_range")
        condition.mType = Condition::Type::CPU_PC_IN_RANGE;
    else if (type == "cpu_pc_out_of_range")
        condition.mType = Condition::Type::CPU_PC_OUT_OF_RANGE;
    else if (type == "and")
        condition.mType = Condition::Type::AND;
    else if (type == "or")
        condition.mType = Condition::Type::OR;
    else if (type == "not")
        condition.mType = Condition::Type::NOT;
    else
    {
        error = "Unknown condition type: " + type;
        return false;
    }

    if (const JsonValue *signal = FindObjectField(json, "signal"))
    {
        if (!RequireString(*signal, "signal", condition.mSignal, error))
            return false;
    }
    if (const JsonValue *value = FindObjectField(json, "value"))
    {
        if (!RequireNumber(*value, "value", condition.mValue, error))
            return false;
    }
    if (const JsonValue *value2 = FindObjectField(json, "value2"))
    {
        if (!RequireNumber(*value2, "value2", condition.mValue2, error))
            return false;
    }
    if (const JsonValue *start = FindObjectField(json, "start"))
    {
        if (!RequireNumber(*start, "start", condition.mValue, error))
            return false;
    }
    if (const JsonValue *end = FindObjectField(json, "end"))
    {
        if (!RequireNumber(*end, "end", condition.mValue2, error))
            return false;
    }
    if (const JsonValue *children = FindObjectField(json, "children"))
    {
        if (!children->IsArray())
        {
            error = "Condition children must be an array";
            return false;
        }
        for (const auto &child : children->mArray)
        {
            Condition parsedChild;
            if (!ParseCondition(child, parsedChild, error))
                return false;
            condition.mChildren.push_back(parsedChild);
        }
    }

    return true;
}

JsonValue MakeSuccessResponse(uint64_t id, const JsonValue &result)
{
    return JsonValue::Object({{"id", JsonValue::Number(id)}, {"ok", JsonValue::Bool(true)}, {"result", result}});
}

JsonValue MakeErrorResponse(uint64_t id, const std::string &code, const std::string &message)
{
    return JsonValue::Object({
        {"id", JsonValue::Number(id)},
        {"ok", JsonValue::Bool(false)},
        {"error", JsonValue::Object({{"code", JsonValue::String(code)}, {"message", JsonValue::String(message)}})},
    });
}

template <typename T>
JsonValue WrapControllerResult(uint64_t id, const ControllerResult<T> &result, const JsonValue &payload)
{
    if (!result.ok)
        return MakeErrorResponse(id, result.errorCode, result.errorMessage);
    return MakeSuccessResponse(id, payload);
}

JsonValue RunResultToJson(const RunResult &result)
{
    return JsonValue::Object({
        {"reason", JsonValue::String(RunStopReasonString(result.mReason))},
        {"ticks_executed", JsonValue::Number(result.mTicksExecuted)},
        {"frames_executed", JsonValue::Number(result.mFramesExecuted)},
    });
}

JsonValue StatusToJson(const SimStatus &status)
{
    return JsonValue::Object({
        {"initialized", JsonValue::Bool(status.mInitialized)},
        {"running", JsonValue::Bool(status.mRunning)},
        {"paused", JsonValue::Bool(status.mPaused)},
        {"trace_active", JsonValue::Bool(status.mTraceActive)},
        {"headless", JsonValue::Bool(status.mHeadless)},
        {"total_ticks", JsonValue::Number(status.mTotalTicks)},
        {"game_name", JsonValue::String(status.mGameName)},
    });
}

JsonValue CpuStateToJson(const CpuState &state)
{
    std::vector<JsonValue> regs;
    regs.reserve(state.mRegisters.size());
    for (uint32_t reg : state.mRegisters)
        regs.push_back(JsonValue::Number(reg));

    return JsonValue::Object({
        {"pc", JsonValue::Number(state.mPc)},
        {"registers", JsonValue::Array(std::move(regs))},
        {"disasm", JsonValue::String(state.mDisasm)},
    });
}

JsonValue Ics2115VoiceToJson(const Ics2115VoiceState &voice)
{
    return JsonValue::Object({
        {"index", JsonValue::Number(voice.mIndex)},
        {"osc_acc", JsonValue::Number(voice.mOscAcc)},
        {"osc_fc", JsonValue::Number(voice.mOscFc)},
        {"osc_start", JsonValue::Number(voice.mOscStart)},
        {"osc_end", JsonValue::Number(voice.mOscEnd)},
        {"osc_saddr", JsonValue::Number(voice.mOscSaddr)},
        {"osc_conf", JsonValue::Number(voice.mOscConf)},
        {"osc_ctl", JsonValue::Number(voice.mOscCtl)},
        {"vol_acc", JsonValue::Number(voice.mVolAcc)},
        {"vol_start", JsonValue::Number(voice.mVolStart)},
        {"vol_end", JsonValue::Number(voice.mVolEnd)},
        {"vol_incr", JsonValue::Number(voice.mVolIncr)},
        {"vol_pan", JsonValue::Number(voice.mVolPan)},
        {"vol_ctrl", JsonValue::Number(voice.mVolCtrl)},
        {"vol_mode", JsonValue::Number(voice.mVolMode)},
        {"state_on", JsonValue::Bool(voice.mStateOn)},
    });
}

JsonValue Ics2115StateToJson(const Ics2115DebugState &state)
{
    std::vector<JsonValue> timers;
    timers.reserve(state.mTimers.size());
    for (size_t i = 0; i < state.mTimers.size(); i++)
    {
        const auto &timer = state.mTimers[i];
        timers.push_back(JsonValue::Object({
            {"index", JsonValue::Number(i)},
            {"preset", JsonValue::Number(timer.mPreset)},
            {"scale", JsonValue::Number(timer.mScale)},
            {"count", JsonValue::Number(timer.mCount)},
            {"period", JsonValue::Number(timer.mPeriod)},
            {"running", JsonValue::Bool(timer.mRunning)},
        }));
    }

    std::vector<JsonValue> voices;
    voices.reserve(state.mVoices.size());
    for (const auto &voice : state.mVoices)
        voices.push_back(Ics2115VoiceToJson(voice));

    return JsonValue::Object({
        {"active_osc", JsonValue::Number(state.mActiveOsc)},
        {"osc_select", JsonValue::Number(state.mOscSelect)},
        {"reg_select", JsonValue::Number(state.mRegSelect)},
        {"vmode", JsonValue::Number(state.mVmode)},
        {"irq_pending", JsonValue::Number(state.mIrqPending)},
        {"irq_enabled", JsonValue::Number(state.mIrqEnabled)},
        {"irq_on", JsonValue::Bool(state.mIrqOn)},
        {"osc_irq_pending_count", JsonValue::Number(state.mOscIrqPendingCount)},
        {"vol_irq_pending_count", JsonValue::Number(state.mVolIrqPendingCount)},
        {"state_on_count", JsonValue::Number(state.mStateOnCount)},
        {"stop_count", JsonValue::Number(state.mStopCount)},
        {"seq_state", JsonValue::Number(state.mSeqState)},
        {"seq_voice_idx", JsonValue::Number(state.mSeqVoiceIdx)},
        {"sample_tick", JsonValue::Bool(state.mSampleTick)},
        {"host", JsonValue::Object({
            {"dout", JsonValue::Number(state.mHostDout)},
            {"cs_n", JsonValue::Bool(state.mHostCsN)},
            {"rd_n", JsonValue::Bool(state.mHostRdN)},
            {"wr_n", JsonValue::Bool(state.mHostWrN)},
            {"irq", JsonValue::Bool(state.mHostIrq)},
            {"ready", JsonValue::Bool(state.mHostReady)},
            {"reset_n", JsonValue::Bool(state.mResetN)},
        })},
        {"rom", JsonValue::Object({
            {"addr", JsonValue::Number(state.mRomAddr)},
            {"data", JsonValue::Number(state.mRomData)},
            {"data_valid", JsonValue::Bool(state.mRomDataValid)},
        })},
        {"audio", JsonValue::Object({
            {"left", JsonValue::SignedNumber(state.mAudioLeft)},
            {"right", JsonValue::SignedNumber(state.mAudioRight)},
            {"valid", JsonValue::Bool(state.mAudioValid)},
        })},
        {"timers", JsonValue::Array(std::move(timers))},
        {"voices", JsonValue::Array(std::move(voices))},
    });
}
} // namespace

SimProtocol::SimProtocol(SimController &controller) : mController(controller)
{
}

std::string SimProtocol::HandleLine(const std::string &line)
{
    uint64_t id = 0;
    std::string error;
    JsonParser parser(line);
    JsonValue request;
    if (!parser.Parse(request, error))
        return SerializeJson(MakeErrorResponse(id, "bad_request", error));
    if (!request.IsObject())
        return SerializeJson(MakeErrorResponse(id, "bad_request", "Request must be a JSON object"));

    const JsonValue *field = nullptr;
    if (!RequireObjectField(request, "id", field, error) || !RequireNumber(*field, "id", id, error))
        return SerializeJson(MakeErrorResponse(id, "bad_request", error));

    std::string method;
    if (!RequireObjectField(request, "method", field, error) || !RequireString(*field, "method", method, error))
        return SerializeJson(MakeErrorResponse(id, "bad_request", error));

    JsonValue params = JsonValue::Object({});
    if (const JsonValue *paramsField = FindObjectField(request, "params"))
        params = *paramsField;

    if (method == "sim.initialize")
    {
        bool headless = true;
        if (const JsonValue *headlessField = FindObjectField(params, "headless"))
        {
            if (!RequireBool(*headlessField, "headless", headless, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        auto result = mController.Initialize(headless);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "sim.shutdown")
    {
        auto result = mController.Shutdown();
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "sim.status")
    {
        auto result = mController.GetStatus();
        return SerializeJson(WrapControllerResult(id, result, StatusToJson(result.value)));
    }
    if (method == "sim.load_game")
    {
        std::string name;
        if (!RequireObjectField(params, "name", field, error) || !RequireString(*field, "name", name, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.LoadGame(name);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "sim.load_mra")
    {
        std::string path;
        if (!RequireObjectField(params, "path", field, error) || !RequireString(*field, "path", path, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.LoadMra(path);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "sim.reset")
    {
        uint64_t cycles = 0;
        if (!RequireObjectField(params, "cycles", field, error) || !RequireNumber(*field, "cycles", cycles, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.Reset(cycles);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "sim.run_cycles")
    {
        uint64_t count = 0;
        if (!RequireObjectField(params, "count", field, error) || !RequireNumber(*field, "count", count, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.RunCycles(count);
        return SerializeJson(WrapControllerResult(id, result, RunResultToJson(result.value)));
    }
    if (method == "sim.run_frames")
    {
        uint64_t count = 0;
        if (!RequireObjectField(params, "count", field, error) || !RequireNumber(*field, "count", count, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.RunFrames(count);
        return SerializeJson(WrapControllerResult(id, result, RunResultToJson(result.value)));
    }
    if (method == "sim.run_until")
    {
        RunUntilRequest requestValue;
        if (!RequireObjectField(params, "condition", field, error) || !ParseCondition(*field, requestValue.mCondition, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        if (const JsonValue *timeoutField = FindObjectField(params, "timeout_cycles"))
        {
            if (!RequireNumber(*timeoutField, "timeout_cycles", requestValue.mTimeoutCycles, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        auto result = mController.RunUntil(requestValue);
        return SerializeJson(WrapControllerResult(id, result, RunResultToJson(result.value)));
    }
    if (method == "cpu.get_state")
    {
        auto result = mController.GetCpuState();
        return SerializeJson(WrapControllerResult(id, result, CpuStateToJson(result.value)));
    }
    if (method == "ics2115.get_state")
    {
        auto result = mController.GetIcs2115DebugState();
        return SerializeJson(WrapControllerResult(id, result, Ics2115StateToJson(result.value)));
    }
    if (method == "ics2115.write_voice")
    {
        uint64_t index = 0;
        Ics2115VoiceState voice;
        if (!RequireObjectField(params, "index", field, error) || !RequireNumber(*field, "index", index, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        voice.mIndex = static_cast<uint32_t>(index);
        const auto readNum = [&](const char *name, uint64_t &out) -> bool {
            const JsonValue *value = FindObjectField(params, name);
            if (!value)
            {
                error = std::string("Missing field: ") + name;
                return false;
            }
            return RequireNumber(*value, name, out, error);
        };
        uint64_t tmp = 0;
        if (!readNum("osc_acc", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mOscAcc = tmp;
        if (!readNum("osc_fc", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mOscFc = tmp;
        if (!readNum("osc_start", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mOscStart = tmp;
        if (!readNum("osc_end", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mOscEnd = tmp;
        if (!readNum("osc_saddr", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mOscSaddr = tmp;
        if (!readNum("osc_conf", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mOscConf = tmp;
        if (!readNum("osc_ctl", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mOscCtl = tmp;
        if (!readNum("vol_acc", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mVolAcc = tmp;
        if (!readNum("vol_start", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mVolStart = tmp;
        if (!readNum("vol_end", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mVolEnd = tmp;
        if (!readNum("vol_incr", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mVolIncr = tmp;
        if (!readNum("vol_pan", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mVolPan = tmp;
        if (!readNum("vol_ctrl", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mVolCtrl = tmp;
        if (!readNum("vol_mode", tmp)) return SerializeJson(MakeErrorResponse(id, "bad_request", error)); voice.mVolMode = tmp;
        const JsonValue *stateOnField = FindObjectField(params, "state_on");
        bool stateOn = false;
        if (stateOnField)
        {
            if (!RequireBool(*stateOnField, "state_on", stateOn, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            voice.mStateOn = stateOn;
        }
        auto result = mController.SetIcs2115VoiceState(static_cast<uint32_t>(index), voice);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "ics2115.write_global")
    {
        std::string name;
        uint64_t value = 0;
        if (!RequireObjectField(params, "name", field, error) || !RequireString(*field, "name", name, error)
            || !RequireObjectField(params, "value", field, error) || !RequireNumber(*field, "value", value, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.SetIcs2115GlobalRegister(name, static_cast<uint32_t>(value));
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "memory.read")
    {
        std::string region;
        uint64_t address = 0;
        uint64_t size = 0;
        if (!RequireObjectField(params, "region", field, error) || !RequireString(*field, "region", region, error)
            || !RequireObjectField(params, "address", field, error) || !RequireNumber(*field, "address", address, error)
            || !RequireObjectField(params, "size", field, error) || !RequireNumber(*field, "size", size, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.ReadMemory(region, static_cast<uint32_t>(address), static_cast<uint32_t>(size));
        JsonValue payload = JsonValue::Object({
            {"region", JsonValue::String(result.value.mRegion)},
            {"address", JsonValue::Number(result.value.mAddress)},
            {"data_hex", JsonValue::String(BytesToHex(result.value.mData))},
        });
        return SerializeJson(WrapControllerResult(id, result, payload));
    }
    if (method == "memory.write")
    {
        std::string region;
        std::string dataHex;
        uint64_t address = 0;
        if (!RequireObjectField(params, "region", field, error) || !RequireString(*field, "region", region, error)
            || !RequireObjectField(params, "address", field, error) || !RequireNumber(*field, "address", address, error)
            || !RequireObjectField(params, "data_hex", field, error) || !RequireString(*field, "data_hex", dataHex, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        std::vector<uint8_t> data;
        if (!HexToBytes(dataHex, data, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.WriteMemory(region, static_cast<uint32_t>(address), data);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "memory.list_regions")
    {
        auto result = mController.ListRegions();
        std::vector<JsonValue> regions;
        for (const auto &region : result.value)
            regions.push_back(JsonValue::String(region));
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Array(std::move(regions))));
    }
    if (method == "debug_link.start")
    {
        uint64_t commsAddr = 0x1F800;
        if (const JsonValue *addrField = FindObjectField(params, "comms_addr"))
        {
            if (!RequireNumber(*addrField, "comms_addr", commsAddr, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        auto result = mController.DebugLinkStart(static_cast<uint32_t>(commsAddr));
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "debug_link.stop")
    {
        auto result = mController.DebugLinkStop();
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "debug_link.write")
    {
        std::string dataHex;
        uint64_t timeoutCycles = 2000000;
        if (!RequireObjectField(params, "data_hex", field, error) || !RequireString(*field, "data_hex", dataHex, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        if (const JsonValue *timeoutField = FindObjectField(params, "timeout_cycles_per_byte"))
        {
            if (!RequireNumber(*timeoutField, "timeout_cycles_per_byte", timeoutCycles, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        std::vector<uint8_t> data;
        if (!HexToBytes(dataHex, data, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.DebugLinkWrite(data, timeoutCycles);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "debug_link.read")
    {
        uint64_t maxBytes = 0;
        uint64_t minBytes = 0;
        uint64_t timeoutCycles = 2000000;
        if (!RequireObjectField(params, "max_bytes", field, error) || !RequireNumber(*field, "max_bytes", maxBytes, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        if (const JsonValue *minField = FindObjectField(params, "min_bytes"))
        {
            if (!RequireNumber(*minField, "min_bytes", minBytes, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        if (const JsonValue *timeoutField = FindObjectField(params, "timeout_cycles"))
        {
            if (!RequireNumber(*timeoutField, "timeout_cycles", timeoutCycles, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        auto result = mController.DebugLinkRead(static_cast<uint32_t>(maxBytes), static_cast<uint32_t>(minBytes), timeoutCycles);
        JsonValue payload = JsonValue::Object({
            {"data_hex", JsonValue::String(BytesToHex(result.value.mData))},
            {"available", JsonValue::Number(result.value.mAvailable)},
        });
        return SerializeJson(WrapControllerResult(id, result, payload));
    }
    if (method == "signal.read")
    {
        std::string name;
        if (!RequireObjectField(params, "name", field, error) || !RequireString(*field, "name", name, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.ReadSignal(name);
        if (!result.ok)
            return SerializeJson(MakeErrorResponse(id, result.errorCode, result.errorMessage));
        JsonValue payload = JsonValue::Object({
            {"name", JsonValue::String(result.value.mSignal)},
            {"value", JsonValue::Number(result.value.mValue)},
            {"width", JsonValue::Number(result.value.mWidth)},
            {"value_hex", JsonValue::String(result.value.mValueHex)},
        });
        return SerializeJson(WrapControllerResult(id, result, payload));
    }
    if (method == "signal.list")
    {
        auto result = mController.ListSignals();
        if (!result.ok)
            return SerializeJson(MakeErrorResponse(id, result.errorCode, result.errorMessage));
        std::vector<JsonValue> signals;
        for (const auto &signal : result.value.mSignals)
        {
            signals.push_back(JsonValue::Object({
                {"name", JsonValue::String(signal.mName)},
                {"width", JsonValue::Number(signal.mWidth)},
                {"kind", JsonValue::String(signal.mKind)},
                {"source", JsonValue::String(signal.mSource)},
            }));
        }
        return SerializeJson(MakeSuccessResponse(id, JsonValue::Object({{"signals", JsonValue::Array(std::move(signals))}})));
    }
    if (method == "state.list")
    {
        auto result = mController.ListStates();
        std::vector<JsonValue> states;
        for (const auto &state : result.value.mStates)
            states.push_back(JsonValue::String(state));
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({{"states", JsonValue::Array(std::move(states))}})));
    }
    if (method == "state.save")
    {
        std::string filename;
        if (!RequireObjectField(params, "filename", field, error) || !RequireString(*field, "filename", filename, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.SaveState(filename);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "state.load")
    {
        std::string filename;
        if (!RequireObjectField(params, "filename", field, error) || !RequireString(*field, "filename", filename, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.LoadState(filename);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "nvram.save")
    {
        std::string filename;
        if (!RequireObjectField(params, "filename", field, error) || !RequireString(*field, "filename", filename, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.SaveNvram(filename);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "nvram.load")
    {
        std::string filename;
        if (!RequireObjectField(params, "filename", field, error) || !RequireString(*field, "filename", filename, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.LoadNvram(filename);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "trace.start")
    {
        std::string filename;
        int depth = 1;
        if (!RequireObjectField(params, "filename", field, error) || !RequireString(*field, "filename", filename, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        if (const JsonValue *depthField = FindObjectField(params, "depth"))
        {
            uint64_t depthValue = 0;
            if (!RequireNumber(*depthField, "depth", depthValue, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            depth = static_cast<int>(depthValue);
        }
        auto result = mController.StartTrace(filename, depth);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "trace.stop")
    {
        auto result = mController.StopTrace();
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "audio_capture.start")
    {
        std::string filename;
        if (!RequireObjectField(params, "filename", field, error) || !RequireString(*field, "filename", filename, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.StartAudioCapture(filename);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "audio_capture.stop")
    {
        auto result = mController.StopAudioCapture();
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "video.screenshot")
    {
        std::string path;
        if (!RequireObjectField(params, "path", field, error) || !RequireString(*field, "path", path, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.SaveScreenshot(path);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({{"path", JsonValue::String(result.value.mPath)}})));
    }
    if (method == "video.set_flip")
    {
        bool flipX = false;
        bool flipY = false;
        if (const JsonValue *fx = FindObjectField(params, "flip_x"))
        {
            if (!RequireBool(*fx, "flip_x", flipX, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        if (const JsonValue *fy = FindObjectField(params, "flip_y"))
        {
            if (!RequireBool(*fy, "flip_y", flipY, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        auto result = mController.SetFlip(flipX, flipY);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({
            {"flip_x", JsonValue::Bool(result.value.mFlipX)},
            {"flip_y", JsonValue::Bool(result.value.mFlipY)},
        })));
    }
    if (method == "gui.get_state")
    {
        auto result = mController.GetGuiState();
        if (!result.ok)
            return SerializeJson(MakeErrorResponse(id, result.errorCode, result.errorMessage));

        std::vector<JsonValue> entries;
        for (const auto &entry : result.value.mEntries)
        {
            entries.push_back(JsonValue::Object({
                {"index", JsonValue::Number(entry.mIndex)},
                {"label", JsonValue::String(entry.mLabel)},
                {"type", JsonValue::Number(entry.mType)},
                {"type_name", JsonValue::String(entry.mTypeName)},
                {"value", JsonValue::Number(entry.mValue)},
                {"override_value", JsonValue::Number(entry.mOverrideValue)},
            }));
        }

        return SerializeJson(MakeSuccessResponse(id, JsonValue::Object({
            {"available", JsonValue::Bool(result.value.mAvailable)},
            {"address", JsonValue::Number(result.value.mAddress)},
            {"last_sync_ticks", JsonValue::Number(result.value.mLastSyncTicks)},
            {"entries", JsonValue::Array(std::move(entries))},
        })));
    }
    if (method == "gui.set_override")
    {
        uint64_t value = 0;
        if (!RequireObjectField(params, "value", field, error) || !RequireNumber(*field, "value", value, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));

        ControllerResult<GuiOverrideResult> result;
        if (const JsonValue *indexField = FindObjectField(params, "index"))
        {
            uint64_t index = 0;
            if (!RequireNumber(*indexField, "index", index, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            result = mController.SetGuiOverrideByIndex(static_cast<uint32_t>(index), static_cast<uint16_t>(value), false);
        }
        else if (const JsonValue *labelField = FindObjectField(params, "label"))
        {
            std::string label;
            if (!RequireString(*labelField, "label", label, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            result = mController.SetGuiOverrideByLabel(label, static_cast<uint16_t>(value), false);
        }
        else
        {
            return SerializeJson(MakeErrorResponse(id, "bad_request", "gui.set_override requires index or label"));
        }

        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({{"applied", JsonValue::Bool(result.value.mApplied)}})));
    }
    if (method == "gui.press_button")
    {
        ControllerResult<GuiOverrideResult> result;
        if (const JsonValue *indexField = FindObjectField(params, "index"))
        {
            uint64_t index = 0;
            if (!RequireNumber(*indexField, "index", index, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            result = mController.SetGuiOverrideByIndex(static_cast<uint32_t>(index), 1, true);
        }
        else if (const JsonValue *labelField = FindObjectField(params, "label"))
        {
            std::string label;
            if (!RequireString(*labelField, "label", label, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            result = mController.SetGuiOverrideByLabel(label, 1, true);
        }
        else
        {
            return SerializeJson(MakeErrorResponse(id, "bad_request", "gui.press_button requires index or label"));
        }

        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({{"applied", JsonValue::Bool(result.value.mApplied)}})));
    }
    if (method == "input.set_dipswitch")
    {
        uint64_t switchIndex = 0;
        if (const JsonValue *switchField = FindObjectField(params, "switch"))
        {
            uint64_t switchNumber = 0;
            if (!RequireNumber(*switchField, "switch", switchNumber, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            if (switchNumber < 1 || switchNumber > 8)
                return SerializeJson(MakeErrorResponse(id, "bad_request", "DIP switch must be 1..8"));
            switchIndex = switchNumber - 1;
        }
        else if (const JsonValue *indexField = FindObjectField(params, "index"))
        {
            if (!RequireNumber(*indexField, "index", switchIndex, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
            if (switchIndex > 7)
                return SerializeJson(MakeErrorResponse(id, "bad_request", "DIP switch index must be 0..7"));
        }
        else
        {
            return SerializeJson(MakeErrorResponse(id, "bad_request", "input.set_dipswitch requires switch or index"));
        }

        bool enabled = false;
        if (const JsonValue *onField = FindObjectField(params, "on"))
        {
            if (!RequireBool(*onField, "on", enabled, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        else if (const JsonValue *enabledField = FindObjectField(params, "enabled"))
        {
            if (!RequireBool(*enabledField, "enabled", enabled, error))
                return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        }
        else
        {
            return SerializeJson(MakeErrorResponse(id, "bad_request", "input.set_dipswitch requires on or enabled"));
        }

        auto result = mController.SetDipSwitch(static_cast<uint8_t>(switchIndex), enabled);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({{"value", JsonValue::Number(mController.GetDipSwitches())}})));
    }
    if (method == "input.set_region")
    {
        uint64_t value = 0;
        if (!RequireObjectField(params, "value", field, error) || !RequireNumber(*field, "value", value, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        if (value > 0xff)
            return SerializeJson(MakeErrorResponse(id, "bad_request", "region value must be 0..255"));

        auto result = mController.SetRegion(static_cast<uint8_t>(value));
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({{"value", JsonValue::Number(mController.GetRegion())}})));
    }
    if (method == "input.get_state")
    {
        auto result = mController.GetInputState();
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({{"buttons", JsonValue::Number(result.value.mButtons)}})));
    }
    if (method == "input.set")
    {
        std::string name;
        if (!RequireObjectField(params, "name", field, error) || !RequireString(*field, "name", name, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.SetInput(name, true);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "input.clear")
    {
        std::string name;
        if (!RequireObjectField(params, "name", field, error) || !RequireString(*field, "name", name, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.ClearInput(name);
        return SerializeJson(WrapControllerResult(id, result, JsonValue::Object({})));
    }
    if (method == "input.press")
    {
        std::string name;
        if (!RequireObjectField(params, "name", field, error) || !RequireString(*field, "name", name, error))
            return SerializeJson(MakeErrorResponse(id, "bad_request", error));
        auto result = mController.PressInput(name);
        return SerializeJson(WrapControllerResult(id, result, RunResultToJson(result.value)));
    }

    return SerializeJson(MakeErrorResponse(id, "unknown_method", "Unknown method: " + method));
}
