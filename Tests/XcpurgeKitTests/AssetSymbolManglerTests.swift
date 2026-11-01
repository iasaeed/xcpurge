import XCTest
@testable import XcpurgeKit

/// Generated asset-symbol names, checked against `actool --generate-swift-asset-symbols` /
/// `--generate-objc-asset-symbols` output (Xcode 26.0.1 and 27.1 beta produced identical results).
final class AssetSymbolManglerTests: XCTestCase {
    /// Probe catalogs: set path (folders prefixed with `~` are plain groups, the others provide a namespace) ->
    /// the Swift symbol and ObjC constant actool generated for it (nil: none, either because the set type has no
    /// symbols, the name has no letters or digits, or an earlier asset or namespace owns the symbol).
    static let probes: [[(path: String, swift: String?, objc: String?)]] = [
    [
        ("1.imageset", "_1", "ACImageName1"),
        ("2fa_icon.imageset", "_2FaIcon", "ACImageName2FaIcon"),
        ("A.imageset", "A", "ACImageNameA"),
        ("ABC.imageset", "ABC", "ACImageNameABC"),
        ("AccentColor.colorset", "accent", "ACColorNameAccentColor"),
        ("Color.colorset", "color", "ACColorNameColor"),
        ("ColorWheel.imageset", "colorWheel", "ACImageNameColorWheel"),
        ("Foo2Bar.imageset", "foo2Bar", "ACImageNameFoo2Bar"),
        ("GreenColor.colorset", "green", "ACColorNameGreenColor"),
        ("HTTPServer.imageset", "httpServer", "ACImageNameHTTPServer"),
        ("IMG_0042.imageset", "IMG_0042", "ACImageName_IMG_0042"),
        ("Ic Wallet.imageset", "icWallet", "ACImageNameIcWallet"),
        ("Icons/my-tabs/home.imageset", "Icons.MyTabs.home", "ACImageNameIconsMyTabsHome"),
        ("Icons/settings_gear.imageset", "Icons.settingsGear", "ACImageNameIconsSettingsGear"),
        ("Image.imageset", "image", "ACImageNameImage"),
        ("LaunchImage.imageset", "launch", "ACImageNameLaunchImage"),
        ("My Icons_2/x.imageset", "MyIcons2.x", "ACImageNameMyIcons2X"),
        ("My_URL_Key.imageset", "myURLKey", "ACImageNameMyURLKey"),
        ("QRCode.imageset", "qrCode", "ACImageNameQRCode"),
        ("QRColor.colorset", "QR", "ACColorNameQRColor"),
        ("Type.imageset", "type", "ACImageNameType"),
        ("URLIcon.imageset", "urlIcon", "ACImageNameURLIcon"),
        ("Zoo.Bar.imageset", "zooBar", "ACImageNameZooBar"),
        ("_.imageset", nil, nil),
        ("_1.imageset", nil, nil),
        ("__double.imageset", "double", "ACImageNameDouble"),
        ("_private.imageset", "`private`", "ACImageNamePrivate"),
        ("a--b.imageset", "aB", "ACImageNameAB"),
        ("a1b2.imageset", "a1B2", "ACImageNameA1B2"),
        ("already_Camel.imageset", "alreadyCamel", "ACImageNameAlreadyCamel"),
        ("async.imageset", "async", "ACImageNameAsync"),
        ("brandColor.colorset", "brand", "ACColorNameBrandColor"),
        ("brandImage.imageset", "brand", "ACImageNameBrandImage"),
        ("cafe-au-lait.imageset", "cafeAuLait", "ACImageNameCafeAuLait"),
        ("data_blob.dataset", nil, nil),
        ("default.imageset", "`default`", "ACImageNameDefault"),
        ("default_c.colorset", "defaultC", "ACColorNameDefaultC"),
        ("description.imageset", "description", "ACImageNameDescription"),
        ("e2e_test.imageset", "e2ETest", "ACImageNameE2ETest"),
        ("fooBAR.imageset", "fooBAR", "ACImageNameFooBAR"),
        ("foo_BAR.imageset", nil, nil),
        ("hello world.imageset", "helloWorld", "ACImageNameHelloWorld"),
        ("iOS_version.imageset", "iOSVersion", "ACImageNameIOSVersion"),
        ("ic-wallet.imageset", nil, nil),
        ("ic_wallet.imageset", nil, nil),
        ("icon 2x.imageset", "icon2X", "ACImageNameIcon2X"),
        ("img_Image.imageset", "img", "ACImageNameImgImage"),
        ("inputContour.imageset", "inputContour", "ACImageNameInputContour"),
        ("inputContourColor.imageset", nil, "ACImageNameInputContourColor"),
        ("logo.dark.imageset", "logoDark", "ACImageNameLogoDark"),
        ("noImage.imageset", "no", "ACImageNameNoImage"),
        ("~plain/in_plain.imageset", "inPlain", "ACImageNameInPlain"),
        ("protocol.imageset", "`protocol`", "ACImageNameProtocol"),
        ("self.imageset", "`self`", "ACImageNameSelf"),
        ("sym_icon.symbolset", "symIcon", "ACImageNameSymIcon"),
        ("trailing_.imageset", "trailing", "ACImageNameTrailing"),
        ("userID.imageset", "userID", "ACImageNameUserID"),
        ("v2.imageset", "v2", "ACImageNameV2"),
        ("x.y.z.imageset", "xYZ", "ACImageNameXYZ"),
        ("x2y.imageset", "x2Y", "ACImageNameX2Y"),
        ("ÄBC.imageset", "ÄBC", "ACImageNameÄBC"),
        ("Ünter.imageset", "ünter", "ACImageNamenter"),
        ("über_icon.imageset", "überIcon", "ACImageNameberIcon"),
    ],
    [
        ("1a_b.imageset", "_1AB", "ACImageName1AB"),
        ("22.imageset", "_22", "ACImageName22"),
        ("2fa/leaf.imageset", "_2Fa.leaf", "ACImageName2FaLeaf"),
        ("2x.imageset", "_2X", "ACImageName2X"),
        ("9lives.imageset", "_9Lives", "ACImageName9Lives"),
        ("AB.imageset", "AB", "ACImageNameAB"),
        ("ABC/leaf.imageset", "ABC.leaf", "ACImageNameABCLeaf"),
        ("ABCLogo.imageset", "abcLogo", "ACImageNameABCLogo"),
        ("ABC_def.imageset", "abcDef", "ACImageNameABCDef"),
        ("ABCd.imageset", "abCd", "ACImageNameABCd"),
        ("ABc.imageset", "aBc", "ACImageNameABc"),
        ("A_B.imageset", "A_B", "ACImageName_A_B"),
        ("Any.imageset", "any", "ACImageNameAny"),
        ("Color/leaf.imageset", "Color.leaf", "ACImageNameColorLeaf"),
        ("Color Color.colorset", "color", "ACColorNameColorColor"),
        ("Color.imageset", nil, "ACImageNameColor"),
        ("ColorColor.colorset", nil, nil),
        ("Done.imageset", "done", "ACImageNameDone"),
        ("HTTP.imageset", "HTTP", "ACImageNameHTTP"),
        ("HTTPFolder/leaf.imageset", "HTTPFolder.leaf", "ACImageNameHTTPFolderLeaf"),
        ("Hello World.imageset", "helloWorld", "ACImageNameHelloWorld"),
        ("IconImage.imageset", "icon", "ACImageNameIconImage"),
        ("Icon_Image.imageset", nil, nil),
        ("Icons Image/leaf.imageset", "Icons.leaf", "ACImageNameIconsImageLeaf"),
        ("Image Image.imageset", "image", "ACImageNameImageImage"),
        ("Image.colorset", "image", "ACColorNameImage"),
        ("Image2.imageset", "image2", "ACImageNameImage2"),
        ("ImageIcon.imageset", "imageIcon", "ACImageNameImageIcon"),
        ("Image_.imageset", nil, "ACImageNameImage"),
        ("Never.imageset", "never", "ACImageNameNever"),
        ("Optional.imageset", "optional", "ACImageNameOptional"),
        ("Protocol.imageset", "`protocol`", "ACImageNameProtocol"),
        ("RED.colorset", "RED", "ACColorNameRED"),
        ("Self.imageset", "`self`", "ACImageNameSelf"),
        ("Star.imageset", "star", "ACImageNameStar"),
        ("Straße.imageset", "straße", "ACImageNameStrae"),
        ("String.imageset", "string", "ACImageNameString"),
        ("Test Image.imageset", "test", "ACImageNameTestImage"),
        ("UIView.imageset", "uiView", "ACImageNameUIView"),
        ("URL.imageset", "URL", "ACImageNameURL"),
        ("X_Y.imageset", "X_Y", "ACImageName_X_Y"),
        ("_Image.imageset", nil, nil),
        ("_lead/leaf.imageset", "Lead.leaf", "ACImageNameLeadLeaf"),
        ("_x.imageset", "x", "ACImageNameX"),
        ("a b/leaf.imageset", "AB.leaf", "ACImageNameABLeaf"),
        ("a-B.imageset", "aB", nil),
        ("a.2.imageset", "a2", "ACImageNameA2"),
        ("a.imageset", "a", "ACImageNameA"),
        ("a2.imageset", nil, nil),
        ("a_2.imageset", nil, nil),
        ("a_ß.imageset", "aSS", "ACImageNameASS"),
        ("ab_C.imageset", "abC", "ACImageNameAbC"),
        ("as.imageset", "`as`", "ACImageNameAs"),
        ("associatedtype.imageset", "`associatedtype`", "ACImageNameAssociatedtype"),
        ("await.imageset", "await", "ACImageNameAwait"),
        ("brand_color.colorset", "brand", "ACColorNameBrandColor"),
        ("café.imageset", "café", "ACImageNameCaf"),
        ("color.colorset", nil, "ACColorNameColor"),
        ("iPhone.imageset", "iPhone", "ACImageNameIPhone"),
        ("ic_wallet2.imageset", "icWallet2", "ACImageNameIcWallet2"),
        ("icon-image.imageset", nil, nil),
        ("icons/Icons.imageset", nil, "ACImageNameIconsIcons"),
        ("icons/Image.imageset", nil, "ACImageNameIconsImage"),
        ("icons/leaf.imageset", nil, "ACImageNameIconsLeaf"),
        ("image.imageset", nil, nil),
        ("imageImage.imageset", nil, nil),
        ("import.imageset", "`import`", "ACImageNameImport"),
        ("in.imageset", "`in`", "ACImageNameIn"),
        ("init.imageset", "`init`", "ACImageNameInit"),
        ("is.imageset", "`is`", "ACImageNameIs"),
        ("japan-street.imageset", "japanStreet", "ACImageNameJapanStreet"),
        ("my URL.imageset", "myURL", "ACImageNameMyURL"),
        ("my-icon_2.imageset", "myIcon2", "ACImageNameMyIcon2"),
        ("myURL.imageset", nil, nil),
        ("my_URL-tabs/leaf.imageset", "MyURLTabs.leaf", "ACImageNameMyURLTabsLeaf"),
        ("naïve_icon.imageset", "naïveIcon", "ACImageNameNaveIcon"),
        ("nil.imageset", "`nil`", "ACImageNameNil"),
        ("~plainA/ns/deep.imageset", "Ns.deep", "ACImageNameNsDeep"),
        ("red_Color.colorset", "red", "ACColorNameRedColor"),
        ("self_.imageset", nil, nil),
        ("smile😀.imageset", "smile", "ACImageNameSmile"),
        ("true.imageset", "`true`", "ACImageNameTrue"),
        ("x-ÄB.imageset", "xÄB", "ACImageNameXB"),
        ("x_Y_z.imageset", "xYZ", "ACImageNameXYZ"),
        ("Éa.imageset", "éa", "ACImageNamea"),
        ("Ünder/leaf.imageset", "Ünder.leaf", "ACImageNamenderLeaf"),
        ("ß.imageset", "ß", "ACImageNameSS"),
        ("é_a.imageset", "éA", nil),
        ("ǅx.imageset", "ǆx", "ACImageNamex"),
        ("日本語.imageset", "日本語", nil),
        ("😀.imageset", nil, nil),
    ],
    [
        ("A B.imageset", "A_B", "ACImageName_A_B"),
        ("A1.imageset", "A_1", "ACImageName_A_1"),
        ("AB CD.imageset", "AB_CD", "ACImageName_AB_CD"),
        ("ABC2.imageset", "ABC_2", "ACImageName_ABC_2"),
        ("ABCDef_G.imageset", "abcDefG", "ACImageNameABCDefG"),
        ("ABC_2d.imageset", "abc2D", "ACImageNameABC2D"),
        ("A_1.imageset", nil, nil),
        ("Ab_CD.imageset", "abCD", "ACImageNameAbCD"),
        ("Abc_DEF.imageset", "abcDEF", "ACImageNameAbcDEF"),
        ("FOO BAR.imageset", "FOO_BAR", "ACImageName_FOO_BAR"),
        ("FOO_bar.imageset", "fooBar", "ACImageNameFOOBar"),
        ("HTTP 2.imageset", "HTTP_2", "ACImageName_HTTP_2"),
        ("HTTP2.imageset", nil, nil),
        ("HTTP_URL.imageset", "HTTP_URL", "ACImageName_HTTP_URL"),
        ("IMG-0042.imageset", "IMG_0042", "ACImageName_IMG_0042"),
        ("NASA.imageset", "NASA", "ACImageNameNASA"),
        ("NASA_logo.imageset", "nasaLogo", "ACImageNameNASALogo"),
        ("Sendable.imageset", "sendable", "ACImageNameSendable"),
        ("USD.imageset", "USD", "ACImageNameUSD"),
        ("Z9.imageset", "Z_9", "ACImageName_Z_9"),
        ("a_USD.imageset", "aUSD", "ACImageNameAUSD"),
        ("actor.imageset", "actor", "ACImageNameActor"),
        ("any.imageset", "any", "ACImageNameAny"),
        ("as.imageset", "`as`", "ACImageNameAs"),
        ("assignment.imageset", "assignment", "ACImageNameAssignment"),
        ("associatedtype.imageset", "`associatedtype`", "ACImageNameAssociatedtype"),
        ("associativity.imageset", "associativity", "ACImageNameAssociativity"),
        ("async.imageset", "async", "ACImageNameAsync"),
        ("await.imageset", "await", "ACImageNameAwait"),
        ("borrowing.imageset", "borrowing", "ACImageNameBorrowing"),
        ("break.imageset", "`break`", "ACImageNameBreak"),
        ("case.imageset", "`case`", "ACImageNameCase"),
        ("catch.imageset", "`catch`", "ACImageNameCatch"),
        ("class.imageset", "`class`", "ACImageNameClass"),
        ("consume.imageset", "consume", "ACImageNameConsume"),
        ("consuming.imageset", "consuming", "ACImageNameConsuming"),
        ("continue.imageset", "`continue`", "ACImageNameContinue"),
        ("convenience.imageset", "convenience", "ACImageNameConvenience"),
        ("copy.imageset", "copy", "ACImageNameCopy"),
        ("debugDescription.imageset", "debugDescription", "ACImageNameDebugDescription"),
        ("default.imageset", "`default`", "ACImageNameDefault"),
        ("defer.imageset", "`defer`", "ACImageNameDefer"),
        ("deinit.imageset", "`deinit`", "ACImageNameDeinit"),
        ("description.imageset", "description", "ACImageNameDescription"),
        ("didSet.imageset", "didSet", "ACImageNameDidSet"),
        ("discard.imageset", "discard", "ACImageNameDiscard"),
        ("do.imageset", "`do`", "ACImageNameDo"),
        ("dynamic.imageset", "dynamic", "ACImageNameDynamic"),
        ("each.imageset", "each", "ACImageNameEach"),
        ("else.imageset", "`else`", "ACImageNameElse"),
        ("enum.imageset", "`enum`", "ACImageNameEnum"),
        ("error.imageset", "error", "ACImageNameError"),
        ("error2.imageset", "error2", "ACImageNameError2"),
        ("extension.imageset", "`extension`", "ACImageNameExtension"),
        ("fallthrough.imageset", "`fallthrough`", "ACImageNameFallthrough"),
        ("false.imageset", "`false`", "ACImageNameFalse"),
        ("fileprivate.imageset", "`fileprivate`", "ACImageNameFileprivate"),
        ("final.imageset", "final", "ACImageNameFinal"),
        ("for.imageset", "`for`", "ACImageNameFor"),
        ("func.imageset", "`func`", "ACImageNameFunc"),
        ("get.imageset", "get", "ACImageNameGet"),
        ("guard.imageset", "`guard`", "ACImageNameGuard"),
        ("hashValue.imageset", "hashValue", "ACImageNameHashValue"),
        ("if.imageset", "`if`", "ACImageNameIf"),
        ("import.imageset", "`import`", "ACImageNameImport"),
        ("in.imageset", "`in`", "ACImageNameIn"),
        ("indirect.imageset", "indirect", "ACImageNameIndirect"),
        ("infix.imageset", "infix", "ACImageNameInfix"),
        ("init.imageset", "`init`", "ACImageNameInit"),
        ("init_.imageset", nil, nil),
        ("inout.imageset", "`inout`", "ACImageNameInout"),
        ("internal.imageset", "`internal`", "ACImageNameInternal"),
        ("is.imageset", "`is`", "ACImageNameIs"),
        ("isolated.imageset", "isolated", "ACImageNameIsolated"),
        ("lazy.imageset", "lazy", "ACImageNameLazy"),
        ("left.imageset", "left", "ACImageNameLeft"),
        ("let.imageset", "`let`", "ACImageNameLet"),
        ("logoNASA.imageset", "logoNASA", "ACImageNameLogoNASA"),
        ("logo_NASA.imageset", nil, nil),
        ("macro.imageset", "macro", "ACImageNameMacro"),
        ("main.imageset", "main", "ACImageNameMain"),
        ("mutating.imageset", "mutating", "ACImageNameMutating"),
        ("nil.imageset", "`nil`", "ACImageNameNil"),
        ("nil_.imageset", nil, nil),
        ("none.imageset", "none", "ACImageNameNone"),
        ("nonisolated.imageset", "nonisolated", "ACImageNameNonisolated"),
        ("nonmutating.imageset", "nonmutating", "ACImageNameNonmutating"),
        ("open.imageset", "open", "ACImageNameOpen"),
        ("operator.imageset", "`operator`", "ACImageNameOperator"),
        ("optional.imageset", "optional", "ACImageNameOptional"),
        ("override.imageset", "override", "ACImageNameOverride"),
        ("package.imageset", "package", "ACImageNamePackage"),
        ("postfix.imageset", "postfix", "ACImageNamePostfix"),
        ("precedence.imageset", "precedence", "ACImageNamePrecedence"),
        ("precedencegroup.imageset", "`precedencegroup`", "ACImageNamePrecedencegroup"),
        ("prefix.imageset", "prefix", "ACImageNamePrefix"),
        ("private.imageset", "`private`", "ACImageNamePrivate"),
        ("protocol.imageset", "`protocol`", "ACImageNameProtocol"),
        ("public.imageset", "`public`", "ACImageNamePublic"),
        ("repeat.imageset", "`repeat`", "ACImageNameRepeat"),
        ("required.imageset", "required", "ACImageNameRequired"),
        ("rethrows.imageset", "`rethrows`", "ACImageNameRethrows"),
        ("return.imageset", "`return`", "ACImageNameReturn"),
        ("right.imageset", "right", "ACImageNameRight"),
        ("self.imageset", "`self`", "ACImageNameSelf"),
        ("sending.imageset", "sending", "ACImageNameSending"),
        ("set.imageset", "set", "ACImageNameSet"),
        ("some.imageset", "some", "ACImageNameSome"),
        ("static.imageset", "`static`", "ACImageNameStatic"),
        ("struct.imageset", "`struct`", "ACImageNameStruct"),
        ("subscript.imageset", "`subscript`", "ACImageNameSubscript"),
        ("super.imageset", "`super`", "ACImageNameSuper"),
        ("switch.imageset", "`switch`", "ACImageNameSwitch"),
        ("throw.imageset", "`throw`", "ACImageNameThrow"),
        ("throws.imageset", "`throws`", "ACImageNameThrows"),
        ("true.imageset", "`true`", "ACImageNameTrue"),
        ("try.imageset", "`try`", "ACImageNameTry"),
        ("type.imageset", "type", "ACImageNameType"),
        ("typealias.imageset", "`typealias`", "ACImageNameTypealias"),
        ("unowned.imageset", "unowned", "ACImageNameUnowned"),
        ("unsafe.imageset", "unsafe", "ACImageNameUnsafe"),
        ("var.imageset", "`var`", "ACImageNameVar"),
        ("weak.imageset", "weak", "ACImageNameWeak"),
        ("where.imageset", "`where`", "ACImageNameWhere"),
        ("while.imageset", "`while`", "ACImageNameWhile"),
        ("willSet.imageset", "willSet", "ACImageNameWillSet"),
        ("Ée.imageset", "ée", "ACImageNamee"),
        ("ÉÉ.imageset", "ÉÉ", "ACImageNameÉÉ"),
        ("é.imageset", "é", nil),
    ],
    [
        ("2x/leaf.imageset", "_2X.leaf", "ACImageName2XLeaf"),
        ("ABC/leaf.imageset", "ABC.leaf", "ACImageNameABCLeaf"),
        ("Color Pack/leaf.imageset", "ColorPack.leaf", "ACImageNameColorPackLeaf"),
        ("HTTP Server/leaf.imageset", "HTTPServer.leaf", "ACImageNameHTTPServerLeaf"),
        ("Icons Image/leaf.imageset", "Icons.leaf", "ACImageNameIconsImageLeaf"),
        ("Image/leaf.imageset", "Image.leaf", "ACImageNameImageLeaf"),
        ("NASA_logo/leaf.imageset", "NASALogo.leaf", "ACImageNameNASALogoLeaf"),
        ("Tabs.imageset", "tabs", "ACImageNameTabs"),
        ("Type/leaf.imageset", "`Type`.leaf", "ACImageNameTypeLeaf"),
        ("URL/leaf.imageset", "URL.leaf", "ACImageNameURLLeaf"),
        ("URLs/leaf.imageset", "URLs.leaf", "ACImageNameURLsLeaf"),
        ("a_b/leaf.imageset", "AB.leaf", "ACImageNameABLeaf"),
        ("default/leaf.imageset", "Default.leaf", "ACImageNameDefaultLeaf"),
        ("hero_image/leaf.imageset", "Hero.leaf", "ACImageNameHeroImageLeaf"),
        ("my-tabs/leaf.imageset", "MyTabs.leaf", "ACImageNameMyTabsLeaf"),
        ("self/leaf.imageset", "`Self`.leaf", "ACImageNameSelfLeaf"),
        ("tab_Bar-icons/leaf.imageset", "TabBarIcons.leaf", "ACImageNameTabBarIconsLeaf"),
        ("tabs/a.imageset", "Tabs.a", "ACImageNameTabsA"),
        ("x.y/leaf.imageset", "XY.leaf", "ACImageNameXYLeaf"),
        ("über/leaf.imageset", "Über.leaf", "ACImageNameberLeaf"),
    ],
    [
        ("Brand Color/pic.imageset", "Brand.pic", "ACImageNameBrandColorPic"),
        ("Brand Color/tint.colorset", "Brand.tint", "ACColorNameBrandColorTint"),
        ("Dup/x.colorset", "Dup.x", "ACColorNameDupX"),
        ("Dup/x.imageset", "Dup.x", "ACImageNameDupX"),
        ("HomeAtlas.spriteatlas", nil, nil),
        ("MyIcon.appiconset", nil, nil),
        ("data_x.dataset", nil, nil),
        ("heart_Color.symbolset", "heart", "ACImageNameHeartColor"),
        ("heart_Image.symbolset", nil, "ACImageNameHeartImage"),
        ("pack_color/pic.imageset", "Pack.pic", "ACImageNamePackColorPic"),
        ("pack_color/tint.colorset", "Pack.tint", "ACColorNamePackColorTint"),
        ("x.colorset", "x", "ACColorNameX"),
        ("x.imageset", "x", "ACImageNameX"),
    ],
    [
        ("COLOR.colorset", "COLOR", "ACColorNameCOLOR"),
        ("Color Image.imageset", "color", "ACImageNameColorImage"),
        ("Image Color.colorset", "image", "ACColorNameImageColor"),
        ("ImageColor.imageset", "image", "ACImageNameImageColor"),
        ("blueColor.imageset", "blue", "ACImageNameBlueColor"),
        ("sym_Image.symbolset", "sym", "ACImageNameSymImage"),
        ("tintImage.colorset", "tint", "ACColorNameTintImage"),
    ],
    [
        ("2FA.imageset", "_2_FA", "ACImageName_2_FA"),
        ("2FA_x.imageset", "_2FAX", "ACImageName2FAX"),
        ("A1/leaf.imageset", "A_1.leaf", "ACImageNameA1Leaf"),
        ("A1b.imageset", "a1B", "ACImageNameA1B"),
        ("AB2CD.imageset", "AB_2_CD", "ACImageName_AB_2_CD"),
        ("ABC2def.imageset", "abc2Def", "ACImageNameABC2Def"),
        ("ABC_.imageset", "ABC", "ACImageNameABC"),
        ("A_B/leaf.imageset", "A_B.leaf", "ACImageNameABLeaf"),
        ("Any/leaf.imageset", "`Any`.leaf", "ACImageNameAnyLeaf"),
        ("COLOR_IMAGE.imageset", "COLOR", "ACImageName_COLOR_IMAGE"),
        ("FOO_Image.imageset", "FOO", "ACImageNameFOOImage"),
        ("IMG_0042/leaf.imageset", "IMG_0042.leaf", "ACImageNameIMG0042Leaf"),
        ("Images.imageset", "images", "ACImageNameImages"),
        ("Protocol/leaf.imageset", "`Protocol`.leaf", "ACImageNameProtocolLeaf"),
        ("RED_COLOR.colorset", "RED", "ACColorName_RED_COLOR"),
        ("Self.imageset", "`self`", "ACImageNameSelf"),
        ("TYPE.imageset", "TYPE", "ACImageNameTYPE"),
        ("Type_.imageset", "type", "ACImageNameType"),
        ("Watercolor.imageset", "watercolor", "ACImageNameWatercolor"),
        ("_ABC.imageset", nil, nil),
        ("colors.colorset", "colors", "ACColorNameColors"),
        ("data_x.dataset", nil, nil),
        ("fooColorImage.imageset", "foo", "ACImageNameFooColorImage"),
        ("image2Color.colorset", "image2", "ACColorNameImage2Color"),
        ("my2Color.colorset", "my2", "ACColorNameMy2Color"),
        ("type/leaf.imageset", "`Type`.leaf", "ACImageNameTypeLeaf"),
        ("x_ABC.imageset", "xABC", "ACImageNameXABC"),
        ("Ä_B.imageset", "Ä_B", "ACImageName_Ä_B"),
        ("ÉÉ_Color.colorset", "ÉÉ", "ACColorNameColor"),
    ],
    [
        ("1_2.imageset", "_1_2", "ACImageName_1_2"),
        ("ABC/leaf.imageset", "ABC.leaf", "ACImageNameABCLeaf"),
        ("ABC.imageset", nil, "ACImageNameABC"),
        ("ALPHA_Color.colorset", "ALPHA", "ACColorNameALPHAColor"),
        ("A_.imageset", "A", "ACImageNameA"),
        ("Bar/x.colorset", "Bar.x", "ACColorNameBarX"),
        ("Bar.imageset", "bar", "ACImageNameBar"),
        ("Baz/y.imageset", "Baz.y", "ACImageNameBazY"),
        ("Baz Image.imageset", "baz", "ACImageNameBazImage"),
        ("ColorImageColor.imageset", "color", "ACImageNameColorImageColor"),
        ("Foo/x.imageset", "Foo.x", "ACImageNameFooX"),
        ("Foo.colorset", "foo", "ACColorNameFoo"),
        ("HTTPS2go.imageset", "https2Go", "ACImageNameHTTPS2Go"),
        ("HTTPs.imageset", "httPs", "ACImageNameHTTPs"),
        ("ImageImageImage.imageset", "image", "ACImageNameImageImageImage"),
        ("Ns/Inner/k.imageset", "Ns.Inner.k", "ACImageNameNsInnerK"),
        ("Ns/Inner.imageset", nil, "ACImageNameNsInner"),
        ("Ns/inner.colorset", "Ns.inner", "ACColorNameNsInner"),
        ("QQ.imageset", "QQ", "ACImageNameQQ"),
        ("Qq/z.imageset", "Qq.z", "ACImageNameQqZ"),
        ("_2fa.imageset", "_2Fa", "ACImageName2Fa"),
        ("_a_B.imageset", "aB", "ACImageNameAB"),
        ("a b c.imageset", "aBC", nil),
        ("a_Color_Color.imageset", "a", "ACImageNameAColorColor"),
        ("aǅ.imageset", "aǆ", nil),
        ("fooImageColorImage.imageset", "foo", "ACImageNameFooImageColorImage"),
        ("smile😀face.imageset", "smileFace", "ACImageNameSmileFace"),
        ("x½.imageset", "x½", "ACImageNameX"),
        ("ÀB_c.imageset", "àbC", "ACImageNameBC"),
        ("ǅǅ.imageset", "ǅǅ", "ACImageNameǅǅ"),
        ("Ⅻ.imageset", "ⅻ", nil),
        ("日本_語.imageset", "日本語", nil),
    ],
    [
        ("AA/x.colorset", "AA.x", "ACColorNameAAX"),
        ("AA_/y.imageset", "AA.y", "ACImageNameAAY"),
        ("KK/k.imageset", "KK.k", "ACImageNameKKK"),
        ("KK_.imageset", "KK", "ACImageNameKK"),
        ("Pp/q.colorset", "Pp.q", "ACColorNamePpQ"),
        ("Pp.colorset", nil, "ACColorNamePp"),
        ("Rr/s.imageset", "Rr.s", "ACImageNameRrS"),
        ("Uu Image/v.imageset", "Uu.v", "ACImageNameUuImageV"),
        ("Uu_/w.imageset", nil, "ACImageNameUuW"),
        ("XY.imageset", "XY", "ACImageNameXY"),
        ("XY_/k.imageset", "XY.k", "ACImageNameXYK"),
        ("rr_/t.imageset", nil, "ACImageNameRrT"),
    ],
    [
        ("~p1/Ns/q_r.imageset", nil, nil),
        ("~p1/ab_c.imageset", nil, nil),
        ("~p2/AbC.imageset", "abC", "ACImageNameAbC"),
        ("~p2/Ns/QR_.imageset", "Ns.QR", "ACImageNameNsQR"),
        ("~p2/Ns/qR.imageset", "Ns.qR", nil),
    ],
    ]

    /// Catalog entries for probe paths, as `AssetCatalogReader` reports them.
    static func assets(_ paths: [String], catalog: String = "P.xcassets") -> [CatalogAsset] {
        paths.map { path in
            let parts = path.split(separator: "/").map(String.init)
            let file = parts.last!
            let leaf = (file as NSString).deletingPathExtension
            let namespace = parts.dropLast().filter { !$0.hasPrefix("~") }
            let relative = parts.map { $0.hasPrefix("~") ? String($0.dropFirst()) : $0 }.joined(separator: "/")
            return CatalogAsset(name: (namespace + [leaf]).joined(separator: "/"), leaf: leaf, namespace: Array(namespace),
                                type: AssetType.byExtension[(file as NSString).pathExtension]!, path: catalog + "/" + relative,
                                catalog: catalog, relativePath: relative, sizeBytes: 0)
        }
    }

    func testEveryProbedNameMatchesActool() {
        var mismatches: [String] = []
        for probes in Self.probes {
            let assets = Self.assets(probes.map(\.path))
            let owned = AssetSymbolMangler.ownedSymbols(in: assets)
            for (probe, asset) in zip(probes, assets) {
                let got = owned[asset.path] ?? .init()
                if got.swift != probe.swift || got.objc != probe.objc {
                    mismatches.append("\(probe.path): swift \(got.swift ?? "nil") (actool \(probe.swift ?? "nil")), "
                        + "objc \(got.objc ?? "nil") (actool \(probe.objc ?? "nil"))")
                }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    func testCollisionLosersOwnNothing() {
        let assets = Self.assets(["ic_wallet.imageset", "ic-wallet.imageset", "Ic Wallet.imageset", "_1.imageset", "1.imageset"])
        let owned = AssetSymbolMangler.ownedSymbols(in: assets)
        XCTAssertEqual(owned["P.xcassets/Ic Wallet.imageset"]?.swift, "icWallet")
        XCTAssertEqual(owned["P.xcassets/ic-wallet.imageset"], .init(swift: nil, objc: nil, lostSwift: true))
        XCTAssertEqual(owned["P.xcassets/ic_wallet.imageset"]?.lostSwift, true)
        XCTAssertEqual(owned["P.xcassets/1.imageset"]?.swift, "_1")
        XCTAssertEqual(owned["P.xcassets/_1.imageset"]?.swift, nil)

        // Same-named sets (image stack layers, several catalogs of one target) share the symbol of their name.
        let layers = AssetSymbolMangler.ownedSymbols(in: Self.assets(["~Front/Content.imageset", "~Back/Content.imageset"]))
        XCTAssertEqual(layers["P.xcassets/Front/Content.imageset"]?.swift, "content")
        XCTAssertEqual(layers["P.xcassets/Back/Content.imageset"], .init(swift: "content", objc: "ACImageNameContent"))

        let folders = AssetSymbolMangler.ownedSymbols(in: Self.assets(["Icons Image/leaf.imageset", "icons/leaf.imageset", "x.imageset"]))
        XCTAssertEqual(folders["P.xcassets/Icons Image/leaf.imageset"], .init(swift: "Icons.leaf", objc: "ACImageNameIconsImageLeaf",
                                                                             orderDependent: true))
        XCTAssertEqual(folders["P.xcassets/icons/leaf.imageset"], .init(objc: "ACImageNameIconsLeaf", lostSwift: true, orderDependent: true))
        XCTAssertEqual(folders["P.xcassets/x.imageset"]?.orderDependent, false)
    }

    func testCandidateHelpers() {
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "brandColor", type: .color), ["brand"])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "default"), ["`default`"])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "home", namespace: ["Icons", "my-tabs"]), ["home", "Icons.MyTabs.home"])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "blob", type: .data), [])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "Home", type: .spriteAtlas), [])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "AppIcon", type: .appIcon), [])
        XCTAssertEqual(AssetSymbolMangler.objcSymbol(leaf: "heart", type: .symbol), "ACImageNameHeart")
        XCTAssertEqual(AssetSymbolMangler.objcSymbol(leaf: "home", type: .image, namespace: ["Icons"]), "ACImageNameIconsHome")
        XCTAssertNil(AssetSymbolMangler.objcSymbol(leaf: "x", type: .data))
        XCTAssertEqual(AssetSymbolMangler.fuzzyKey("brand_mark"), AssetSymbolMangler.fuzzyKey("brandMark"))
    }

    // MARK: - Live check against the installed actool

    /// Rebuilds every probe catalog, compiles it with the installed `actool` and checks that the mangler agrees
    /// with the generated symbols name by name, so a future Xcode that changes the rules fails here.
    /// Skipped where `xcrun actool` is unavailable.
    func testManglerAgreesWithInstalledActool() throws {
        guard let actool = Self.xcrun(["--sdk", "iphoneos", "--find", "actool"]) else {
            throw XCTSkip("xcrun actool is not available")
        }
        let root = try FixtureSupport.tempTree([:])
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
        var mismatches: [String] = []
        for (n, probes) in Self.probes.enumerated() {
            let catalog = "P\(n).xcassets"
            let dir = root.appendingPathComponent(catalog)
            try Self.writeCatalog(probes.map(\.path), at: dir, png: png)
            let out = root.appendingPathComponent("out\(n)")
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let swiftFile = out.appendingPathComponent("GeneratedAssetSymbols.swift").path
            let objcFile = out.appendingPathComponent("GeneratedAssetSymbols.h").path
            _ = Self.run(actool, [dir.path, "--compile", out.path, "--platform", "iphoneos",
                                  "--minimum-deployment-target", "17.0", "--generate-swift-asset-symbol-extensions", "YES",
                                  "--generate-swift-asset-symbols", swiftFile, "--generate-objc-asset-symbols", objcFile,
                                  "--bundle-identifier", "com.example.probe", "--output-format", "human-readable-text"])
            guard let swift = try? String(contentsOfFile: swiftFile, encoding: .utf8),
                  let objc = try? String(contentsOfFile: objcFile, encoding: .utf8) else {
                return XCTFail("actool produced no symbol files for \(catalog)")
            }
            let generated = Self.parseGenerated(swift: swift, objc: objc)
            let assets = AssetCatalogReader.read(catalog: catalog, root: root)
            XCTAssertEqual(assets.count, probes.count, catalog)
            let owned = AssetSymbolMangler.ownedSymbols(in: assets)
            for asset in assets {
                let kind = asset.type == .color ? "color" : "image"
                let want = generated[asset.name + "|" + kind] ?? (nil, nil)
                let got = owned[asset.path] ?? .init()
                // Which of two folders mangling to one enum keeps it depends on how the catalog was written.
                if (got.swift != want.swift && !got.orderDependent) || got.objc != want.objc {
                    mismatches.append("\(asset.relativePath): swift \(got.swift ?? "nil") (actool \(want.swift ?? "nil")), "
                        + "objc \(got.objc ?? "nil") (actool \(want.objc ?? "nil"))")
                }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    static func writeCatalog(_ paths: [String], at dir: URL, png: Data) throws {
        let fm = FileManager.default
        let info = #""info":{"version":1,"author":"xcode"}"#
        func write(_ text: String, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write("{\(info)}", dir.appendingPathComponent("Contents.json"))
        for path in paths {
            var folder = dir
            for part in path.split(separator: "/").dropLast() {
                let plain = part.hasPrefix("~")
                folder.appendPathComponent(plain ? String(part.dropFirst()) : String(part))
                let contents = folder.appendingPathComponent("Contents.json")
                if !fm.fileExists(atPath: contents.path) {
                    try write(plain ? "{\(info)}" : #"{\#(info),"properties":{"provides-namespace":true}}"#, contents)
                }
            }
            let set = folder.appendingPathComponent(String(path.split(separator: "/").last!))
            switch set.pathExtension {
            case "imageset":
                try write(#"{"images":[{"idiom":"universal","filename":"p.png"}],\#(info)}"#, set.appendingPathComponent("Contents.json"))
                try png.write(to: set.appendingPathComponent("p.png"))
            case "colorset":
                try write(#"{"colors":[{"idiom":"universal","color":{"color-space":"srgb","components":"#
                    + #"{"red":"1","green":"0","blue":"0","alpha":"1"}}}],\#(info)}"#, set.appendingPathComponent("Contents.json"))
            case "symbolset":
                try write(#"{"symbols":[{"filename":"s.svg","idiom":"universal"}],\#(info)}"#, set.appendingPathComponent("Contents.json"))
                try write(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#, set.appendingPathComponent("s.svg"))
            case "dataset":
                try write(#"{"data":[{"filename":"d.txt","idiom":"universal"}],\#(info)}"#, set.appendingPathComponent("Contents.json"))
                try write("x", set.appendingPathComponent("d.txt"))
            default:
                try write("{\(info)}", set.appendingPathComponent("Contents.json"))
            }
        }
    }

    /// `name|image` / `name|color` -> qualified Swift symbol and ObjC constant from actool's generated files.
    static func parseGenerated(swift: String, objc: String) -> [String: (swift: String?, objc: String?)] {
        var out: [String: (swift: String?, objc: String?)] = [:]
        var kind: String?
        var enums: [String] = []
        for line in swift.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("extension DeveloperToolsSupport.ImageResource {") { kind = "image"; enums = []; continue }
            if line.hasPrefix("extension DeveloperToolsSupport.ColorResource {") { kind = "color"; enums = []; continue }
            guard let k = kind else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("}") { kind = nil; continue }
            if trimmed.hasPrefix("enum "), trimmed.hasSuffix(" {") {
                enums.append(String(trimmed.dropFirst(5).dropLast(2)))
            } else if trimmed == "}" {
                _ = enums.popLast()
            } else if trimmed.hasPrefix("static let "), let eq = trimmed.range(of: " = "),
                      let name = trimmed.range(of: "(name: \""), let end = trimmed.range(of: "\", bundle:") {
                let symbol = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 11)..<eq.lowerBound])
                out[String(trimmed[name.upperBound..<end.lowerBound]) + "|" + k, default: (nil, nil)].swift =
                    (enums + [symbol]).joined(separator: ".")
            }
        }
        for line in objc.split(separator: "\n").map(String.init) where line.hasPrefix("static NSString * const AC") {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 5, fields[4] != "ACBundleID", let at = line.range(of: "@\"") else { continue }
            let name = String(line[at.upperBound...].dropLast(2))
            let kind = fields[4].hasPrefix("ACColorName") ? "color" : "image"
            out[name + "|" + kind, default: (nil, nil)].objc = fields[4]
        }
        return out
    }

    /// Path printed by `xcrun <args>`, nil when xcrun or the tool is missing.
    static func xcrun(_ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun") else { return nil }
        let (status, output) = run("/usr/bin/xcrun", args)
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return status == 0 && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    @discardableResult
    static func run(_ executable: String, _ args: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
