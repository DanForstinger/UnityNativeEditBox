#if UNITY_EDITOR
// #if false

#region

using TMPro;
using UnityEngine;

#endregion

public partial class NativeEditBox
{
    private void AwakeNative()
    {
        inputField.onEndEdit.AddListener(OnEndEdit);
        inputField.onValueChanged.AddListener(OnValueChanged);
    }

    private void OnValueChanged(string text)
    {
        OnTextChanged?.Invoke(text);
    }

    private void OnEndEdit(string text)
    {
        if (Input.GetKey(KeyCode.KeypadEnter) || Input.GetKey(KeyCode.Return))
            OnSubmit?.Invoke(inputField.text);

        OnDidEnd?.Invoke();
        OnTapOutside?.Invoke();
    }

    #region Public Methods

    public static bool IsKeyboardSupported()
    {
        return false;
    }

    public void SetPlaceholder(string text)
    {
        inputField.placeholder.GetComponent<TextMeshProUGUI>().text = text;
    }

    public void SetText(string text)
    {
        inputField.text = text;
    }

    public void SelectRange(int from, int to)
    {
        inputField.selectionAnchorPosition = from;
        inputField.selectionFocusPosition = to;
    }

    public void SetPlacement(int left, int top, int right, int bottom)
    {
        //Do nothing
    }

    public void ActivateInputField()
    {
        inputField.ActivateInputField();
    }

    public void DestroyNative()
    {
        //Do nothing
    }

    public string text
    {
        set => SetText(value);
        get => inputField.text;
    }

    #endregion

    #region BAD FOCUS CHECK

    private bool wasFocused;

    private void UpdateNative()
    {
        var focus = inputField.isFocused;

        if (focus != wasFocused)
        {
            wasFocused = focus;

            if (focus)
            {
                OnGotFocus?.Invoke();

                if (inputField.onFocusSelectAll)
                    SelectRange(0, inputField.text.Length);
            }
        }
    }

    #endregion
}

#endif