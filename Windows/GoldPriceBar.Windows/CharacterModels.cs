using System.Windows;
using GoldPriceBar.Core;

namespace GoldPriceBar.Windows;

internal enum CharacterEmotion
{
    Happy,
    Sad,
}

internal enum CharacterPose
{
    Happy,
    HappyCheer,
    HappyHeart,
    HappySleepy,
    HappyWave,
    HappyWink,
    HappyClap,
    HappyDance,
    HappyThumbsUp,
    Sad,
    SadStomp,
    SadTear,
    SadTurn,
    SadPout,
    SadHide,
    SadSigh,
    SadFacepalm,
    SadShiver,
}

internal static class CharacterPoseInfo
{
    private static readonly CharacterPose[] HappyActions =
    [
        CharacterPose.HappyWave, CharacterPose.HappyWink, CharacterPose.HappyCheer,
        CharacterPose.HappyHeart, CharacterPose.HappySleepy, CharacterPose.HappyClap,
        CharacterPose.HappyDance, CharacterPose.HappyThumbsUp,
    ];

    private static readonly CharacterPose[] SadActions =
    [
        CharacterPose.SadPout, CharacterPose.SadHide, CharacterPose.SadStomp,
        CharacterPose.SadTear, CharacterPose.SadTurn, CharacterPose.SadSigh,
        CharacterPose.SadFacepalm, CharacterPose.SadShiver,
    ];

    internal static CharacterPose Base(CharacterEmotion emotion) =>
        emotion == CharacterEmotion.Sad ? CharacterPose.Sad : CharacterPose.Happy;

    internal static IReadOnlyList<CharacterPose> Actions(CharacterEmotion emotion) =>
        emotion == CharacterEmotion.Sad ? SadActions : HappyActions;

    internal static string ResourceName(this CharacterPose pose) => pose switch
    {
        CharacterPose.Happy => "character-happy",
        CharacterPose.HappyCheer => "character-happy-cheer",
        CharacterPose.HappyHeart => "character-happy-heart",
        CharacterPose.HappySleepy => "character-happy-sleepy",
        CharacterPose.HappyWave => "character-happy-wave",
        CharacterPose.HappyWink => "character-happy-wink",
        CharacterPose.HappyClap => "character-happy-clap",
        CharacterPose.HappyDance => "character-happy-dance",
        CharacterPose.HappyThumbsUp => "character-happy-thumbs-up",
        CharacterPose.Sad => "character-sad",
        CharacterPose.SadStomp => "character-sad-stomp",
        CharacterPose.SadTear => "character-sad-tear",
        CharacterPose.SadTurn => "character-sad-turn",
        CharacterPose.SadPout => "character-sad-pout",
        CharacterPose.SadHide => "character-sad-hide",
        CharacterPose.SadSigh => "character-sad-sigh",
        CharacterPose.SadFacepalm => "character-sad-facepalm",
        CharacterPose.SadShiver => "character-sad-shiver",
        _ => "character-happy",
    };

    internal static Rect SignRect(this CharacterPose pose) => pose switch
    {
        CharacterPose.Happy => new(0.235, 0.470, 0.395, 0.145),
        CharacterPose.HappyCheer => new(0.235, 0.450, 0.422, 0.190),
        CharacterPose.HappyHeart => new(0.251, 0.474, 0.450, 0.179),
        CharacterPose.HappySleepy => new(0.255, 0.478, 0.447, 0.175),
        CharacterPose.HappyWave => new(0.245, 0.465, 0.405, 0.150),
        CharacterPose.HappyWink => new(0.275, 0.485, 0.410, 0.145),
        CharacterPose.HappyClap => new(0.303, 0.498, 0.355, 0.162),
        CharacterPose.HappyDance => new(0.283, 0.439, 0.332, 0.141),
        CharacterPose.HappyThumbsUp => new(0.279, 0.479, 0.408, 0.174),
        CharacterPose.Sad => new(0.225, 0.485, 0.425, 0.155),
        CharacterPose.SadStomp => new(0.215, 0.478, 0.443, 0.183),
        CharacterPose.SadTear => new(0.199, 0.470, 0.462, 0.207),
        CharacterPose.SadTurn => new(0.203, 0.526, 0.498, 0.191),
        CharacterPose.SadPout => new(0.210, 0.485, 0.430, 0.160),
        CharacterPose.SadHide => new(0.260, 0.455, 0.455, 0.155),
        CharacterPose.SadSigh => new(0.281, 0.475, 0.400, 0.189),
        CharacterPose.SadFacepalm => new(0.266, 0.447, 0.416, 0.191),
        CharacterPose.SadShiver => new(0.303, 0.473, 0.348, 0.166),
        _ => new(0.235, 0.470, 0.395, 0.145),
    };

    internal static (double Width, double Height) FullSize(this CharacterSize size)
    {
        var value = (double)(int)size;
        return (value, value);
    }

    internal static (double Width, double Height) DockedSize(this CharacterSize size) => size switch
    {
        CharacterSize.Small => (165, 103),
        CharacterSize.Standard => (180, 112),
        CharacterSize.Large => (195, 122),
        _ => (180, 112),
    };
}

internal enum SpeechKind
{
    Ambient,
    Click,
    DoubleClick,
    Impatient,
    Hide,
    RapidRise,
    RapidFall,
    Sleeping,
    Wake,
}

internal static class SpeechCatalog
{
    private static readonly string[] HappyAmbient = ["今天也在认真盯盘～", "金价会往哪边走呢？", "别忘了偶尔休息一下！", "我会一直帮你看着的～"];
    private static readonly string[] SadAmbient = ["先别慌，再观察一下……", "跌一点也要保持冷静。", "我会继续认真盯盘的！", "希望下一次刷新能涨回来。"];
    private static readonly string[] HappyClick = ["收到！继续盯盘～", "嘿嘿，被发现啦！", "今天也要好运！"];
    private static readonly string[] SadClick = ["我没事，再看看吧……", "再点一下也不会涨啦。", "陪我等它涨回来吧。"];

    internal static string Text(SpeechKind kind, CharacterEmotion emotion, double delta = 0) => kind switch
    {
        SpeechKind.Ambient => Pick(emotion == CharacterEmotion.Sad ? SadAmbient : HappyAmbient),
        SpeechKind.Click => Pick(emotion == CharacterEmotion.Sad ? SadClick : HappyClick),
        SpeechKind.DoubleClick => emotion == CharacterEmotion.Sad ? "哼！看我生气给你看！" : "双击收到，庆祝一下！",
        SpeechKind.Impatient => "别再点啦，我要不耐烦了！",
        SpeechKind.Hide => "哼，我先躲到牌子后面！",
        SpeechKind.RapidRise => $"哇！刚刚一下涨了 {Math.Abs(delta):F2} 元！",
        SpeechKind.RapidFall => $"呜……刚刚一下跌了 {Math.Abs(delta):F2} 元。",
        SpeechKind.Sleeping => "Zzz…",
        SpeechKind.Wake => "醒啦，继续盯盘！",
        _ => "继续盯盘～",
    };

    private static string Pick(IReadOnlyList<string> values) => values[Random.Shared.Next(values.Count)];
}

internal sealed record CharacterPlacement(
    double Left,
    double Top,
    string Monitor,
    bool Docked,
    DockEdge DockEdge);
