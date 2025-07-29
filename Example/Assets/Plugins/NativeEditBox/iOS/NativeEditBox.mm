//
//  CNativeEditBox.mm
//
//  Updates:
//   • Placeholder now works for both UITextField and UITextView.
//   • Touch handling fixed: taps outside the native input are NOT
//     consumed by iOS and will propagate to Unity (so your Unity
//     UI still receives button presses while the keyboard/input is up).
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <string.h>

#pragma mark - Unity glue -----------------------------------------------------

extern "C" UIViewController *UnityGetGLViewController();

static inline char *MakeStringCopy(const char *string)
{
    if (string == NULL) return NULL;
    char *res = (char *)malloc(strlen(string) + 1);
    strcpy(res, string);
    return res;
}

#pragma mark - Enums ----------------------------------------------------------

typedef NS_ENUM(NSInteger, TextAnchor)
{
    TextAnchorUpperLeft,
    TextAnchorUpperCenter,
    TextAnchorUpperRight,
    TextAnchorMiddleLeft,
    TextAnchorMiddleCenter,
    TextAnchorMiddleRight,
    TextAnchorLowerLeft,
    TextAnchorLowerCenter,
    TextAnchorLowerRight
};

typedef NS_ENUM(NSInteger, InputType)
{
    InputTypeStandard,
    InputTypeAutoCorrect,
    InputTypePassword,
};

typedef NS_ENUM(NSInteger, TouchScreenKeyboardType)
{
    TouchScreenKeyboardTypeDefault,
    TouchScreenKeyboardTypeASCIICapable,
    TouchScreenKeyboardTypeNumbersAndPunctuation,
    TouchScreenKeyboardTypeURL,
    TouchScreenKeyboardTypeNumberPad,
    TouchScreenKeyboardTypePhonePad,
    TouchScreenKeyboardTypeNamePhonePad,
    TouchScreenKeyboardTypeEmailAddress,
};

typedef NS_ENUM(NSInteger, ReturnButtonType)
{
    ReturnButtonTypeDefault,
    ReturnButtonTypeGo,
    ReturnButtonTypeNext,
    ReturnButtonTypeSearch,
    ReturnButtonTypeSend,
    ReturnButtonTypeDone,
};

#pragma mark - C‑side delegate types -----------------------------------------

typedef void (*DelegateKeyboardChanged)(float x, float y, float width, float height);
typedef void (*DelegateWithText)(int instanceId, const char *text);
typedef void (*DelegateEmpty)(int instanceId);

static DelegateKeyboardChanged delegateKeyboardChanged = NULL;
static DelegateWithText        delegateTextChanged     = NULL;
static DelegateWithText        delegateDidEnd          = NULL;
static DelegateWithText        delegateSubmitPressed   = NULL;
static DelegateEmpty           delegateGotFocus        = NULL;
static DelegateEmpty           delegateTapOutside      = NULL;

#pragma mark - CEditBoxPlugin -------------------------------------------------

// NOTE: UIGestureRecognizerDelegate added to allow passthrough touches.
@interface CEditBoxPlugin : NSObject <UITextFieldDelegate, UITextViewDelegate, UIGestureRecognizerDelegate>
{
    int   instanceId;
    UIView *editView;
    int   characterLimit;
    UITapGestureRecognizer *tapper;

    // UILabel used to emulate UITextView placeholder.
    UILabel *placeholderLabel;
}
@end

@implementation CEditBoxPlugin

#pragma mark Init / Dealloc ---------------------------------------------------

- (id)initWithInstanceId:(int)instanceId_ multiline:(BOOL)multiline
{
    self = [super init];
    if (!self) return nil;

    instanceId       = instanceId_;
    characterLimit   = 0;
    placeholderLabel = nil;

    if (!multiline)
        [self initTextField];
    else
        [self initTextView];

    UIView *view = UnityGetGLViewController().view;
    [view addSubview:editView];

    // IMPORTANT: Make tapper non-interfering and pass-through so Unity still
    // receives its touches. We only use it to close the keyboard.
    tapper = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                     action:@selector(handleSingleTap:)];
    tapper.cancelsTouchesInView       = NO;   // critical change: do NOT swallow touches
    tapper.delaysTouchesBegan         = NO;
    tapper.delaysTouchesEnded         = NO;
    tapper.requiresExclusiveTouchType = NO;
    tapper.delegate                   = self; // so we can ignore touches inside editView
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    [editView resignFirstResponder];
    [editView removeFromSuperview];

    UIView *view = UnityGetGLViewController().view;
    [view removeGestureRecognizer:tapper];
}

#pragma mark Tap handling (keyboard dismiss) ---------------------------------

- (void)handleSingleTap:(UITapGestureRecognizer *)sender
{
    if (![editView isFirstResponder]) return;

    // End editing (dismiss keyboard), but because cancelsTouchesInView == NO,
    // the same tap will still propagate to Unity UI.
    UIView *view = UnityGetGLViewController().view;
    [view endEditing:YES];

    if (delegateTapOutside)
        delegateTapOutside(instanceId);
}

#pragma mark UIGestureRecognizerDelegate (passthrough rules) -----------------

// Only consider taps when the text input is active.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer
{
    return [editView isFirstResponder];
}

// Allow Unity (and other recognizers) to receive touches alongside this one.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer
{
    return YES;
}

// Don't trigger our tapper for touches that start inside the native edit control.
// That way, typing/tapping inside the field isn't affected. Everywhere else is
// fair game (to close keyboard) but the touch still goes through to Unity.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch
{
    if (!editView) return YES;
    CGPoint p = [touch locationInView:editView];
    BOOL inside = [editView pointInside:p withEvent:nil];
    return !inside;
}

#pragma mark Setup widgets ----------------------------------------------------

- (void)initTextField
{
    UITextField *textField       = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    textField.tag                = 0;
    textField.delegate           = self;
    textField.clearButtonMode    = UITextFieldViewModeWhileEditing;
    textField.backgroundColor    = UIColor.clearColor;

    [textField addTarget:self
                  action:@selector(textFieldDidChange:)
        forControlEvents:UIControlEventEditingChanged];

    editView = textField;
}

- (void)initTextView
{
    UITextView *textView   = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    textView.tag           = 0;
    textView.delegate      = self;
    textView.editable      = YES;
    textView.scrollEnabled = YES;
    textView.contentInset  = UIEdgeInsetsZero;
    textView.backgroundColor = UIColor.clearColor;
    editView = textView;

    // Placeholder label to emulate missing UITextView placeholder API.
    placeholderLabel = [[UILabel alloc] init];
    placeholderLabel.numberOfLines            = 0;
    placeholderLabel.backgroundColor          = UIColor.clearColor;
    placeholderLabel.userInteractionEnabled   = NO; // let touches pass through
    [textView addSubview:placeholderLabel];
    [self updatePlaceholderFrame];
}

#pragma mark Placeholder helpers ---------------------------------------------

- (void)updatePlaceholderFrame
{
    if (![editView isKindOfClass:[UITextView class]] || !placeholderLabel) return;

    UITextView *tv = (UITextView *)editView;
    UIEdgeInsets insets = tv.textContainerInset;

    CGFloat startX    = insets.left + 4.0f;
    CGFloat startY    = insets.top;
    CGFloat maxWidth  = tv.frame.size.width - startX - insets.right - 4.0f;

    CGSize s = [placeholderLabel sizeThatFits:CGSizeMake(maxWidth, CGFLOAT_MAX)];
    placeholderLabel.frame = CGRectMake(startX, startY, s.width, s.height);
}

#pragma mark UITextField delegate --------------------------------------------

- (void)textFieldDidBeginEditing:(UITextField *)textField
{
    UIView *view = UnityGetGLViewController().view;
    [view addGestureRecognizer:tapper];

    if (delegateGotFocus)
        delegateGotFocus(instanceId);
}

- (BOOL)textField:(UITextField *)textField
 shouldChangeCharactersInRange:(NSRange)range
 replacementString:(NSString *)string
{
    if (characterLimit == 0) return YES;

    NSUInteger oldLen = textField.text.length;
    NSUInteger newLen = oldLen - range.length + string.length;
    BOOL returnKey    = [string rangeOfString:@"\n"].location != NSNotFound;

    return (newLen <= characterLimit) || returnKey;
}

- (void)textFieldDidEndEditing:(UITextField *)textField
{
    [self onTextDidEnd:textField.text];

    UIView *view = UnityGetGLViewController().view;
    [view removeGestureRecognizer:tapper];
}

- (void)textFieldDidChange:(UITextField *)textField
{
    [self onTextChange:textField.text];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    if (delegateSubmitPressed)
        delegateSubmitPressed(instanceId, MakeStringCopy(textField.text.UTF8String));
    return YES;
}

#pragma mark UITextView delegate ---------------------------------------------

- (void)textViewDidBeginEditing:(UITextView *)textView
{
    UIView *view = UnityGetGLViewController().view;
    [view addGestureRecognizer:tapper];

    if (delegateGotFocus)
        delegateGotFocus(instanceId);
}

- (BOOL)textView:(UITextView *)textView
shouldChangeTextInRange:(NSRange)range
 replacementText:(NSString *)replacementText
{
    if (characterLimit == 0) return YES;

    NSUInteger oldLen = textView.text.length;
    NSUInteger newLen = oldLen - range.length + replacementText.length;
    return newLen <= characterLimit;
}

- (void)textViewDidEndEditing:(UITextView *)textView
{
    [self onTextDidEnd:textView.text];

    UIView *view = UnityGetGLViewController().view;
    [view removeGestureRecognizer:tapper];
}

- (void)textViewDidChange:(UITextView *)textView
{
    [self onTextChange:textView.text];
    if (placeholderLabel)
        placeholderLabel.hidden = (textView.text.length != 0);
}

#pragma mark Internal callbacks ---------------------------------------------

- (void)onTextDidEnd:(NSString *)text
{
    if (delegateDidEnd)
        delegateDidEnd(instanceId, MakeStringCopy(text.UTF8String));
}

- (void)onTextChange:(NSString *)text
{
    if (delegateTextChanged)
        delegateTextChanged(instanceId, MakeStringCopy(text.UTF8String));
}

#pragma mark Public setters ---------------------------------------------------

- (void)setFocus:(BOOL)doFocus
{
    if (doFocus)
        [editView becomeFirstResponder];
    else
        [editView resignFirstResponder];
}

- (void)setPlacement:(int)left top:(int)top right:(int)right bottom:(int)bottom
{
    UIView *view = UnityGetGLViewController().view;
    CGFloat scale = 1.f / [self getScale:view];

    CGRect f;
    f.origin.x    = left   * scale;
    f.origin.y    = top    * scale;
    f.size.width  = (right  - left)  * scale;
    f.size.height = (bottom - top)   * scale;
    [editView setFrame:f];

    if (placeholderLabel)
        [self updatePlaceholderFrame];
}

- (void)setPlaceholder:(NSString *)text color:(UIColor *)color
{
    if ([editView isKindOfClass:[UITextField class]])
    {
        UITextField *field = (UITextField *)editView;
        NSDictionary *attrs = @{
            NSForegroundColorAttributeName : color,
            NSFontAttributeName            : [UIFont boldSystemFontOfSize:field.font.pointSize]
        };
        field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:text
                                                                      attributes:attrs];
    }
    else if ([editView isKindOfClass:[UITextView class]])
    {
        UITextView *tv = (UITextView *)editView;
        if (!placeholderLabel)
        {
            placeholderLabel = [[UILabel alloc] init];
            placeholderLabel.numberOfLines          = 0;
            placeholderLabel.backgroundColor        = UIColor.clearColor;
            placeholderLabel.userInteractionEnabled = NO;
            [tv addSubview:placeholderLabel];
        }
        placeholderLabel.text      = text;
        placeholderLabel.textColor = color;
        placeholderLabel.font      = [UIFont boldSystemFontOfSize:tv.font.pointSize];
        placeholderLabel.hidden    = (tv.text.length != 0);
        [self updatePlaceholderFrame];
    }
}

- (void)setFontSize:(int)size
{
    UIView *view = UnityGetGLViewController().view;
    CGFloat scale = 1.f / [self getScale:view];

    CGFloat fSize = size * scale;

    if ([editView isKindOfClass:[UITextField class]])
        [(UITextField *)editView setFont:[UIFont boldSystemFontOfSize:fSize]];
    else
        [(UITextView  *)editView setFont:[UIFont boldSystemFontOfSize:fSize]];

    if (placeholderLabel)
        placeholderLabel.font = [UIFont boldSystemFontOfSize:fSize];
}

- (void)setFontColor:(UIColor *)color
{
    if ([editView isKindOfClass:[UITextField class]])
        [(UITextField *)editView setTextColor:color];
    else
        [(UITextView  *)editView setTextColor:color];
}

- (void)setTextAlignment:(TextAnchor)anchor
{
    NSTextAlignment txtAlign;
    UIControlContentVerticalAlignment vAlign;

    switch (anchor)
    {
        case TextAnchorUpperLeft:   txtAlign = NSTextAlignmentLeft;   vAlign = UIControlContentVerticalAlignmentTop;    break;
        case TextAnchorUpperCenter: txtAlign = NSTextAlignmentCenter; vAlign = UIControlContentVerticalAlignmentTop;    break;
        case TextAnchorUpperRight:  txtAlign = NSTextAlignmentRight;  vAlign = UIControlContentVerticalAlignmentTop;    break;
        case TextAnchorMiddleLeft:  txtAlign = NSTextAlignmentLeft;   vAlign = UIControlContentVerticalAlignmentCenter; break;
        case TextAnchorMiddleCenter:txtAlign = NSTextAlignmentCenter; vAlign = UIControlContentVerticalAlignmentCenter; break;
        case TextAnchorMiddleRight: txtAlign = NSTextAlignmentRight;  vAlign = UIControlContentVerticalAlignmentCenter; break;
        case TextAnchorLowerLeft:   txtAlign = NSTextAlignmentLeft;   vAlign = UIControlContentVerticalAlignmentBottom; break;
        case TextAnchorLowerCenter: txtAlign = NSTextAlignmentCenter; vAlign = UIControlContentVerticalAlignmentBottom; break;
        case TextAnchorLowerRight:  txtAlign = NSTextAlignmentRight;  vAlign = UIControlContentVerticalAlignmentBottom; break;
    }

    if ([editView isKindOfClass:[UITextField class]])
    {
        UITextField *field = (UITextField *)editView;
        field.textAlignment            = txtAlign;
        field.contentVerticalAlignment = vAlign;
    }
    else
    {
        ((UITextView *)editView).textAlignment = txtAlign;
    }
}

- (void)setInputType:(InputType)inputType
{
    UITextAutocorrectionType autocorr;
    BOOL secure;

    switch (inputType)
    {
        case InputTypeStandard:   autocorr = UITextAutocorrectionTypeNo;  secure = NO; break;
        case InputTypeAutoCorrect:autocorr = UITextAutocorrectionTypeYes; secure = NO; break;
        case InputTypePassword:   autocorr = UITextAutocorrectionTypeNo;  secure = YES;break;
    }

    if ([editView isKindOfClass:[UITextField class]])
    {
        UITextField *f = (UITextField *)editView;
        f.autocorrectionType = autocorr;
        f.secureTextEntry    = secure;
    }
    else
    {
        UITextView *tv = (UITextView *)editView;
        tv.autocorrectionType = autocorr;
        tv.secureTextEntry    = secure;
    }
}

- (void)setKeyboardType:(TouchScreenKeyboardType)keyboardType
{
    UITextAutocapitalizationType autocap =
        (keyboardType == TouchScreenKeyboardTypeEmailAddress)
        ? UITextAutocapitalizationTypeNone
        : UITextAutocapitalizationTypeSentences;

    UIKeyboardType kb;
    switch (keyboardType)
    {
        case TouchScreenKeyboardTypeDefault:               kb = UIKeyboardTypeDefault;               break;
        case TouchScreenKeyboardTypeASCIICapable:          kb = UIKeyboardTypeASCIICapableNumberPad; break;
        case TouchScreenKeyboardTypeNumbersAndPunctuation: kb = UIKeyboardTypeNumbersAndPunctuation; break;
        case TouchScreenKeyboardTypeURL:                   kb = UIKeyboardTypeURL;                   break;
        case TouchScreenKeyboardTypeNumberPad:             kb = UIKeyboardTypeNumberPad;             break;
        case TouchScreenKeyboardTypePhonePad:              kb = UIKeyboardTypePhonePad;              break;
        case TouchScreenKeyboardTypeNamePhonePad:          kb = UIKeyboardTypeNamePhonePad;          break;
        case TouchScreenKeyboardTypeEmailAddress:          kb = UIKeyboardTypeEmailAddress;          break;
    }

    if ([editView isKindOfClass:[UITextField class]])
    {
        UITextField *f = (UITextField *)editView;
        f.autocapitalizationType = autocap;
        f.keyboardType           = kb;
    }
    else
    {
        UITextView *tv = (UITextView *)editView;
        tv.autocapitalizationType = autocap;
        tv.keyboardType           = kb;
    }
}

- (void)setReturnButtonType:(ReturnButtonType)returnButtonType
{
    UIReturnKeyType rk;
    switch (returnButtonType)
    {
        case ReturnButtonTypeDefault: rk = UIReturnKeyDefault; break;
        case ReturnButtonTypeGo:      rk = UIReturnKeyGo;      break;
        case ReturnButtonTypeNext:    rk = UIReturnKeyNext;    break;
        case ReturnButtonTypeSearch:  rk = UIReturnKeySearch;  break;
        case ReturnButtonTypeSend:    rk = UIReturnKeySend;    break;
        case ReturnButtonTypeDone:    rk = UIReturnKeyDone;    break;
    }

    if ([editView isKindOfClass:[UITextField class]])
        ((UITextField *)editView).returnKeyType = rk;
    else
        ((UITextView  *)editView).returnKeyType = rk;
}

- (void)setCharacterLimit:(int)characterLimit_
{
    characterLimit = characterLimit_;
}

- (void)setText:(NSString *)newText
{
    if ([editView isKindOfClass:[UITextField class]])
        ((UITextField *)editView).text = newText;
    else
        ((UITextView  *)editView).text = newText;

    if (placeholderLabel)
        placeholderLabel.hidden = (newText.length != 0);
}

- (void)showClearButton:(BOOL)show
{
    if ([editView isKindOfClass:[UITextField class]])
    {
        UITextField *f = (UITextField *)editView;
        f.clearButtonMode = show ? UITextFieldViewModeWhileEditing
                                 : UITextFieldViewModeNever;
    }
}

- (void)selectRangeFrom:(int)from rangeTo:(int)to
{
    if ([editView isKindOfClass:[UITextField class]])
    {
        UITextField *f = (UITextField *)editView;
        UITextPosition *pFrom = [f positionFromPosition:f.beginningOfDocument offset:from];
        UITextPosition *pTo   = [f positionFromPosition:f.beginningOfDocument offset:to];
        if (!pFrom || !pTo) return;
        UITextRange *r = [f textRangeFromPosition:pFrom toPosition:pTo];
        if (!r) return;
        [f setSelectedTextRange:r];
    }
    else
    {
        UITextView *tv = (UITextView *)editView;
        UITextPosition *pFrom = [tv positionFromPosition:tv.beginningOfDocument offset:from];
        UITextPosition *pTo   = [tv positionFromPosition:tv.beginningOfDocument offset:to];
        if (!pFrom || !pTo) return;
        UITextRange *r = [tv textRangeFromPosition:pFrom toPosition:pTo];
        if (!r) return;
        [tv setSelectedTextRange:r];
    }
}

#pragma mark Helpers ---------------------------------------------------------

- (CGFloat)getScale:(UIView *)view
{
    if (UIDevice.currentDevice.systemVersion.floatValue >= 8.0)
        return view.window.screen.nativeScale;
    return view.contentScaleFactor;
}

@end  // CEditBoxPlugin

#pragma mark - CEditBoxGlobalPlugin ------------------------------------------

@interface CEditBoxGlobalPlugin : NSObject
@end

@implementation CEditBoxGlobalPlugin

- (id)init
{
    self = [super init];
    if (!self) return nil;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(keyboardShow:)
               name:UIKeyboardWillShowNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardShow:)
               name:UIKeyboardDidShowNotification  object:nil];
    [nc addObserver:self selector:@selector(keyboardHide:)
               name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardHide:)
               name:UIKeyboardDidHideNotification  object:nil];
    return self;
}

- (void)dealloc
{
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)keyboardShow:(NSNotification *)notification
{
    NSDictionary *info   = notification.userInfo;
    CGRect kb            = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];

    CGFloat scale        = [self getScale:UnityGetGLViewController().view];
    kb.origin.x         *= scale;
    kb.origin.y         *= scale;
    kb.size.width       *= scale;
    kb.size.height      *= scale;

    if (delegateKeyboardChanged)
        delegateKeyboardChanged(kb.origin.x, kb.origin.y, kb.size.width, kb.size.height);
}

- (void)keyboardHide:(NSNotification *)notification
{
    if (delegateKeyboardChanged)
        delegateKeyboardChanged(0, 0, 0, 0);
}

- (CGFloat)getScale:(UIView *)view
{
    if (UIDevice.currentDevice.systemVersion.floatValue >= 8.0)
        return view.window.screen.nativeScale;
    return view.contentScaleFactor;
}

@end  // CEditBoxGlobalPlugin

#pragma mark - C API bridge ---------------------------------------------------

static CEditBoxGlobalPlugin *globalPlugin = nil;

extern "C"
{
// creation / destruction
void  *_CNativeEditBox_Init(int instanceId, BOOL multiline);
void   _CNativeEditBox_Destroy(void *instance);

// setters
void _CNativeEditBox_SetFocus(void *instance, BOOL doFocus);
void _CNativeEditBox_SetPlacement(void *instance, int l, int t, int r, int b);
void _CNativeEditBox_SetPlaceholder(void *instance, const char *t, float R, float G, float B, float A);
void _CNativeEditBox_SetFontSize(void *instance, int size);
void _CNativeEditBox_SetFontColor(void *instance, float R, float G, float B, float A);
void _CNativeEditBox_SetTextAlignment(void *instance, int alignment);
void _CNativeEditBox_SetInputType(void *instance, int inputType);
void _CNativeEditBox_SetKeyboardType(void *instance, int keyboardType);
void _CNativeEditBox_SetReturnButtonType(void *instance, int returnType);
void _CNativeEditBox_SetCharacterLimit(void *instance, int limit);
void _CNativeEditBox_SetText(void *instance, const char *t);
void _CNativeEditBox_ShowClearButton(void *instance, BOOL show);
void _CNativeEditBox_SelectRange(void *instance, int from, int to);

// callbacks
void _CNativeEditBox_RegisterKeyboardChangedCallback(DelegateKeyboardChanged cb);
void _CNativeEditBox_RegisterTextCallbacks(DelegateWithText changed,
                                           DelegateWithText didEnd,
                                           DelegateWithText submit);
void _CNativeEditBox_RegisterEmptyCallbacks(DelegateEmpty gotFocus,
                                            DelegateEmpty tapOutside);
}

void *_CNativeEditBox_Init(int instanceId, BOOL multiline)
{
    if (globalPlugin == nil)
        globalPlugin = [[CEditBoxGlobalPlugin alloc] init];

    id instance = [[CEditBoxPlugin alloc] initWithInstanceId:instanceId
                                                   multiline:multiline];
    return (__bridge_retained void *)instance;
}

void _CNativeEditBox_Destroy(void *instance)
{
    CEditBoxPlugin *p = (__bridge_transfer CEditBoxPlugin *)instance;
    p = nil;
}

void _CNativeEditBox_SetFocus(void *instance, BOOL doFocus)
{
    [(__bridge CEditBoxPlugin *)instance setFocus:doFocus];
}

void _CNativeEditBox_SetPlacement(void *instance, int l, int t, int r, int b)
{
    [(__bridge CEditBoxPlugin *)instance setPlacement:l top:t right:r bottom:b];
}

void _CNativeEditBox_SetPlaceholder(void *instance, const char *t,
                                    float R, float G, float B, float A)
{
    UIColor *col = [UIColor colorWithRed:R green:G blue:B alpha:A];
    [(__bridge CEditBoxPlugin *)instance setPlaceholder:[NSString stringWithUTF8String:t]
                                                  color:col];
}

void _CNativeEditBox_SetFontSize(void *instance, int size)
{
    [(__bridge CEditBoxPlugin *)instance setFontSize:size];
}

void _CNativeEditBox_SetFontColor(void *instance, float R, float G, float B, float A)
{
    UIColor *col = [UIColor colorWithRed:R green:G blue:B alpha:A];
    [(__bridge CEditBoxPlugin *)instance setFontColor:col];
}

void _CNativeEditBox_SetTextAlignment(void *instance, int alignment)
{
    [(__bridge CEditBoxPlugin *)instance setTextAlignment:(TextAnchor)alignment];
}

void _CNativeEditBox_SetInputType(void *instance, int inputType)
{
    [(__bridge CEditBoxPlugin *)instance setInputType:(InputType)inputType];
}

void _CNativeEditBox_SetKeyboardType(void *instance, int keyboardType)
{
    [(__bridge CEditBoxPlugin *)instance setKeyboardType:(TouchScreenKeyboardType)keyboardType];
}

void _CNativeEditBox_SetReturnButtonType(void *instance, int returnType)
{
    [(__bridge CEditBoxPlugin *)instance setReturnButtonType:(ReturnButtonType)returnType];
}

void _CNativeEditBox_SetCharacterLimit(void *instance, int limit)
{
    [(__bridge CEditBoxPlugin *)instance setCharacterLimit:limit];
}

void _CNativeEditBox_SetText(void *instance, const char *t)
{
    [(__bridge CEditBoxPlugin *)instance setText:[NSString stringWithUTF8String:t]];
}

void _CNativeEditBox_ShowClearButton(void *instance, BOOL show)
{
    [(__bridge CEditBoxPlugin *)instance showClearButton:show];
}

void _CNativeEditBox_SelectRange(void *instance, int from, int to)
{
    [(__bridge CEditBoxPlugin *)instance selectRangeFrom:from rangeTo:to];
}

void _CNativeEditBox_RegisterKeyboardChangedCallback(DelegateKeyboardChanged cb)
{
    delegateKeyboardChanged = cb;
}

void _CNativeEditBox_RegisterTextCallbacks(DelegateWithText changed,
                                           DelegateWithText didEnd,
                                           DelegateWithText submit)
{
    delegateTextChanged   = changed;
    delegateDidEnd        = didEnd;
    delegateSubmitPressed = submit;
}

void _CNativeEditBox_RegisterEmptyCallbacks(DelegateEmpty gotFocus,
                                            DelegateEmpty tapOutside)
{
    delegateGotFocus  = gotFocus;
    delegateTapOutside = tapOutside;
}
