// File: lib/firebase_options.dart

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError('iOS not configured.');
      case TargetPlatform.macOS:
        throw UnsupportedError('macOS not configured.');
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
  //  apiKey: 'AIzaSyA1a01MEHq5MV2Lkjffn_ZGEyU1MctYslU',
    apiKey: "AIzaSyDjG1zZW-eJmZCDvxpqX2CHZW0Kk7N2xPA",
  //  authDomain: 'hotel-admin-app-ccdcf.firebaseapp.com',
    authDomain: "arun-ecomerce.firebaseapp.com",
    databaseURL: 'https://arun-ecomerce-default-rtdb.firebaseio.com',
   // projectId: 'hotel-admin-app-ccdcf',

    projectId: "arun-ecomerce",
   // storageBucket: 'hotel-admin-app-ccdcf.firebasestorage.app',
    storageBucket: "arun-ecomerce.firebasestorage.app",
  //  messagingSenderId: '795680161445',
    messagingSenderId: "133445015000",
   /* appId: '1:795680161445:web:66a22a8470aa2b579a174c',
    measurementId: 'G-D8NM9DMDMZ',*/

      appId: "1:133445015000:web:a978001af98cb2b6374ead",
      measurementId: "G-301PVW3F2W"
  );
// For Firebase JS SDK v7.20.0 and later, measurementId is optional
  
  static const FirebaseOptions android = FirebaseOptions(
   // apiKey: 'AIzaSyA1a01MEHq5MV2Lkjffn_ZGEyU1MctYslU',
    apiKey: "AIzaSyDjG1zZW-eJmZCDvxpqX2CHZW0Kk7N2xPA",
    databaseURL: 'https://arun-ecomerce-default-rtdb.firebaseio.com',
    //projectId: 'hotel-admin-app-ccdcf',

    projectId: "arun-ecomerce",
   // storageBucket: 'hotel-admin-app-ccdcf.firebasestorage.app',
    storageBucket: "arun-ecomerce.firebasestorage.app",
  //  messagingSenderId: '795680161445',
    messagingSenderId: "133445015000",
    //appId: '1:795680161445:web:66a22a8470aa2b579a174c',

      appId: "1:133445015000:web:a978001af98cb2b6374ead",
      measurementId: "G-301PVW3F2W"
  );
}
