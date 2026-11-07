using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ImgShare.Core;

/// <summary>Windows DPAPI (CryptProtectData), an den aktuellen Benutzer gebunden. Ohne NuGet-Abhängigkeit.</summary>
internal static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)]
    struct DataBlob { public int Size; public IntPtr Data; }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptProtectData(ref DataBlob pDataIn, string? description, ref DataBlob pEntropy,
        IntPtr reserved, IntPtr prompt, int flags, ref DataBlob pDataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CryptUnprotectData(ref DataBlob pDataIn, IntPtr description, ref DataBlob pEntropy,
        IntPtr reserved, IntPtr prompt, int flags, ref DataBlob pDataOut);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr mem);

    const int UiForbidden = 0x1;

    public static byte[] Protect(byte[] data, byte[] entropy) => Run(data, entropy, protect: true);
    public static byte[] Unprotect(byte[] data, byte[] entropy) => Run(data, entropy, protect: false);

    static byte[] Run(byte[] data, byte[] entropy, bool protect)
    {
        var hData = GCHandle.Alloc(data, GCHandleType.Pinned);
        var hEnt = GCHandle.Alloc(entropy, GCHandleType.Pinned);
        try
        {
            var inBlob = new DataBlob { Size = data.Length, Data = hData.AddrOfPinnedObject() };
            var entBlob = new DataBlob { Size = entropy.Length, Data = hEnt.AddrOfPinnedObject() };
            var outBlob = new DataBlob();
            bool ok = protect
                ? CryptProtectData(ref inBlob, "ImgShare", ref entBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, ref outBlob)
                : CryptUnprotectData(ref inBlob, IntPtr.Zero, ref entBlob, IntPtr.Zero, IntPtr.Zero, UiForbidden, ref outBlob);
            if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
            try
            {
                var result = new byte[outBlob.Size];
                Marshal.Copy(outBlob.Data, result, 0, outBlob.Size);
                return result;
            }
            finally { LocalFree(outBlob.Data); }
        }
        finally { hData.Free(); hEnt.Free(); }
    }
}
