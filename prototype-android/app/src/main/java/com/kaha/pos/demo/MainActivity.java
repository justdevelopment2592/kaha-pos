package com.kaha.pos.demo;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Insets;
import android.os.Build;
import android.os.Bundle;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;
import androidx.webkit.WebViewAssetLoader;

/** Kaha POS UI prototype in a native shell. Not the production Flutter app; no server connection. */
public class MainActivity extends Activity {
  private WebView web;

  @Override protected void onCreate(Bundle saved) {
    super.onCreate(saved);
    final WebViewAssetLoader loader = new WebViewAssetLoader.Builder()
        .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
        .build();

    web = new WebView(this);
    WebSettings s = web.getSettings();
    s.setJavaScriptEnabled(true);
    s.setDomStorageEnabled(true);
    s.setAllowFileAccess(false);
    s.setAllowContentAccess(false);
    s.setTextZoom(100);
    web.setWebViewClient(new WebViewClient() {
      @Override public WebResourceResponse shouldInterceptRequest(WebView v, WebResourceRequest r) {
        return loader.shouldInterceptRequest(r.getUrl());
      }
    });

    // A WebView ignores its own padding, so a plain container takes the system-bar insets instead.
    // This keeps the status bar (clock, camera cutout) and the gesture bar clear of the app.
    FrameLayout root = new FrameLayout(this);
    root.setBackgroundColor(Color.parseColor("#FBFCF9"));
    root.addView(web, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    root.setOnApplyWindowInsetsListener((View v, WindowInsets in) -> {
      if (Build.VERSION.SDK_INT >= 30) {
        Insets i = in.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
        v.setPadding(i.left, i.top, i.right, i.bottom);
      } else {
        v.setPadding(in.getSystemWindowInsetLeft(), in.getSystemWindowInsetTop(), in.getSystemWindowInsetRight(), in.getSystemWindowInsetBottom());
      }
      return WindowInsets.CONSUMED;
    });
    root.setFitsSystemWindows(false);

    setContentView(root);
    root.requestApplyInsets();
    if (saved != null) web.restoreState(saved);
    else web.loadUrl("https://appassets.androidplatform.net/assets/www/index.html");
  }

  @Override protected void onSaveInstanceState(Bundle out) { super.onSaveInstanceState(out); web.saveState(out); }
  @Override protected void onDestroy() { if (web != null) web.destroy(); super.onDestroy(); }
}
