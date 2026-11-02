using System;
using System.IO;
using System.Media;
using System.Runtime.InteropServices;
using System.Text;

/// <summary>
/// Plays the completion chime at a level that follows the Windows master volume.
/// Compiled once into assets/DshChime.dll so a chime costs one short PowerShell start.
/// </summary>
public static class DshChime
{
    // ---- Windows CoreAudio: read the default output device's master volume ----

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int NotImpl1();
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams,
            [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
    }

    [ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioEndpointVolume
    {
        int NotImpl1();
        int NotImpl2();
        int NotImpl3();
        int NotImpl4();
        int NotImpl5();
        int NotImpl6();
        int GetMasterVolumeLevelScalar(out float level);
    }

    /// <summary>Default playback device master volume in 0..1; throws when unavailable.</summary>
    public static float MasterVolume()
    {
        IMMDeviceEnumerator enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
        IMMDevice device;
        int hr = enumerator.GetDefaultAudioEndpoint(0, 1, out device);
        if (hr != 0) throw new InvalidOperationException("GetDefaultAudioEndpoint hr=0x" + hr.ToString("X8"));
        Guid iid = typeof(IAudioEndpointVolume).GUID;
        object raw;
        hr = device.Activate(ref iid, 1, IntPtr.Zero, out raw);
        if (hr != 0) throw new InvalidOperationException("Activate hr=0x" + hr.ToString("X8"));
        float level;
        hr = ((IAudioEndpointVolume)raw).GetMasterVolumeLevelScalar(out level);
        if (hr != 0) throw new InvalidOperationException("GetMasterVolumeLevelScalar hr=0x" + hr.ToString("X8"));
        return level;
    }

    // ---- Playback ----

    /// <summary>
    /// Play <paramref name="wavPath"/> scaled so its peak lands near
    /// <paramref name="targetPeak"/> once the system volume is applied.
    /// Returns the gain that was used, or a negative number when nothing played.
    /// </summary>
    public static float Ding(string wavPath, float targetPeak, bool adaptive, float maxGain)
    {
        float gain = targetPeak;
        if (adaptive)
        {
            float volume;
            try { volume = MasterVolume(); }
            catch { volume = 0.75f; }          // no probe: assume a normal desktop level
            if (volume < 0.02f) return -1f;    // muted: stay silent instead of firing a process
            gain = targetPeak / volume;
        }
        if (gain > maxGain) gain = maxGain;
        if (gain < 0.02f) gain = 0.02f;
        if (gain > 1f) gain = 1f;

        byte[] scaled = ScaleWav(File.ReadAllBytes(wavPath), gain);
        using (MemoryStream stream = new MemoryStream(scaled, false))
        using (SoundPlayer player = new SoundPlayer(stream))
        {
            player.PlaySync();
        }
        return gain;
    }

    private static byte[] ScaleWav(byte[] raw, float gain)
    {
        int dataOffset = -1;
        int dataLength = 0;
        int pos = 12;
        while (pos + 8 <= raw.Length)
        {
            string id = Encoding.ASCII.GetString(raw, pos, 4);
            int size = BitConverter.ToInt32(raw, pos + 4);
            if (id == "data")
            {
                dataOffset = pos + 8;
                dataLength = Math.Min(size, raw.Length - dataOffset);
                break;
            }
            pos += 8 + size + (size & 1);
        }
        if (dataOffset < 0) throw new InvalidDataException("WAV has no data chunk; expected PCM");

        byte[] output = new byte[raw.Length];
        Buffer.BlockCopy(raw, 0, output, 0, raw.Length);
        for (int i = dataOffset; i + 1 < dataOffset + dataLength; i += 2)
        {
            short sample = BitConverter.ToInt16(raw, i);
            int value = (int)Math.Round(sample * (double)gain);
            if (value > 32767) value = 32767;
            else if (value < -32768) value = -32768;
            output[i] = (byte)(value & 0xFF);
            output[i + 1] = (byte)((value >> 8) & 0xFF);
        }
        return output;
    }
}
