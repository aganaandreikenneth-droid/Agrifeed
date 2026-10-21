import { getApps, initializeApp } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { getDatabase } from "firebase-admin/database";

if (getApps().length === 0) initializeApp();

export const auth = getAuth();
export const db = getDatabase();
