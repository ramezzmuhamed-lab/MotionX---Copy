const translations = {
    ar: {
        "nav-home": "الرئيسية", "nav-owners": "الملاك", "nav-cars": "السيارات", "nav-customers": "العملاء",
        "nav-contracts": "العقود", "nav-payments": "المدفوعات", "nav-expenses": "المصروفات", "nav-reports": "التقارير", "nav-settings": "الإعدادات",
        "title-dashboard": "لوحة التحكم الرئيسية", "title-owners": "إدارة ملاك السيارات", "title-cars": "إدارة السيارات",
        "title-customers": "إدارة العملاء", "title-contracts": "إدارة العقود", "title-payments": "سجل المدفوعات",
        "title-expenses": "المصروفات", "title-reports": "التقارير الشاملة", "title-settings": "إعدادات النظام",
        "user-admin": "مسؤول النظام", "stat-cars": "إجمالي السيارات", "stat-owners": "عدد الملاك",
        "stat-customers": "عدد العملاء", "stat-contracts": "عدد العقود", "stat-revenues": "إجمالي الإيرادات",
        "stat-expenses-total": "إجمالي المصروفات", "stat-profit": "صافي الأرباح"
    },
    en: {
        "nav-home": "Dashboard", "nav-owners": "Owners", "nav-cars": "Cars", "nav-customers": "Customers",
        "nav-contracts": "Contracts", "nav-payments": "Payments", "nav-expenses": "Expenses", "nav-reports": "Reports", "nav-settings": "Settings",
        "title-dashboard": "Main Dashboard", "title-owners": "Owners Hub", "title-cars": "Fleet Gallery",
        "title-customers": "Customers Index", "title-contracts": "Contracts Board", "title-payments": "Payments Ledger",
        "title-expenses": "Expenses Outflow", "title-reports": "Analytics & Reports", "title-settings": "Preferences",
        "user-admin": "System Admin", "stat-cars": "Total Cars", "stat-owners": "Total Owners",
        "stat-customers": "Total Customers", "stat-contracts": "Total Contracts", "stat-revenues": "Total Revenues",
        "stat-expenses-total": "Total Expenses", "stat-profit": "Net Profit"
    }
};

document.addEventListener('DOMContentLoaded', () => {
    const themeToggleBtn = document.getElementById('theme-toggle');
    const langToggleBtn = document.getElementById('lang-toggle');
    const tabButtons = document.querySelectorAll('.tab-btn');
    const tabContents = document.querySelectorAll('.tab-content');
    const pageTitle = document.getElementById('page-title');

    // 1. نظام تشغيل الـ Dark / Light Mode
    function initTheme() {
        const savedTheme = localStorage.getItem('theme') || 'dark'; // افتراضي داكن
        const icon = themeToggleBtn.querySelector('i');
        
        if (savedTheme === 'dark') {
            document.documentElement.classList.add('dark');
            document.body.className = "bg-slate-950 text-slate-100 antialiased h-screen overflow-hidden flex";
            icon.className = "fa-solid fa-sun text-lg text-amber-400";
        } else {
            document.documentElement.classList.remove('dark');
            document.body.className = "bg-slate-50 text-slate-800 antialiased h-screen overflow-hidden flex";
            icon.className = "fa-solid fa-moon text-lg text-slate-500";
        }
    }

    themeToggleBtn.addEventListener('click', () => {
        const isDark = document.documentElement.classList.contains('dark');
        localStorage.setItem('theme', isDark ? 'light' : 'dark');
        initTheme();
    });

    // 2. إدارة اللغات وعكس الاتجاه التلقائي (RTL / LTR)
    function applyLanguage(lang) {
        localStorage.setItem('lang', lang);
        
        if (lang === 'en') {
            document.documentElement.setAttribute('dir', 'ltr');
            document.documentElement.setAttribute('lang', 'en');
            document.documentElement.classList.add('lang-en');
            langToggleBtn.innerText = 'AR';
            
            // تعديل اتجاه التلميحات (Tooltips) في السايدبار الإنجليزي
            document.querySelectorAll('.tab-btn span').forEach(el => {
                el.classList.remove('right-24');
                el.classList.add('left-24');
            });
        } else {
            document.documentElement.setAttribute('dir', 'rtl');
            document.documentElement.setAttribute('lang', 'ar');
            document.documentElement.classList.remove('lang-en');
            langToggleBtn.innerText = 'EN';
            
            document.querySelectorAll('.tab-btn span').forEach(el => {
                el.classList.remove('left-24');
                el.classList.add('right-24');
            });
        }

        // ترجمة الكلمات والرموز في الواجهة
        document.querySelectorAll('[data-i18n]').forEach(element => {
            const key = element.getAttribute('data-i18n');
            if (translations[lang] && translations[lang][key]) {
                element.innerText = translations[lang][key];
            }
        });
    }

    langToggleBtn.addEventListener('click', () => {
        const currentLang = localStorage.getItem('lang') || 'ar';
        const newLang = currentLang === 'ar' ? 'en' : 'ar';
        applyLanguage(newLang);
        
        const activeTabBtn = document.querySelector('.tab-btn.bg-blue-600');
        if (activeTabBtn) {
            const targetTab = activeTabBtn.getAttribute('data-tab');
            pageTitle.innerText = translations[newLang][`title-${targetTab}`] || translations[newLang][`nav-${targetTab}`];
        }
    });

    // 3. نظام التنقل والتحكم في الـ Tabs
    tabButtons.forEach(btn => {
        btn.addEventListener('click', () => {
            const targetTab = btn.getAttribute('data-tab');
            const currentLang = localStorage.getItem('lang') || 'ar';

            tabButtons.forEach(b => {
                b.classList.remove('bg-blue-600', 'text-white');
                b.classList.add('text-slate-400', 'hover:bg-slate-800/50', 'hover:text-white');
            });

            btn.classList.add('bg-blue-600', 'text-white');
            btn.classList.remove('text-slate-400', 'hover:bg-slate-800/50', 'hover:text-white');

            tabContents.forEach(content => {
                content.classList.remove('active');
                if (content.id === `tab-${targetTab}`) {
                    content.classList.add('active');
                }
            });

            pageTitle.innerText = translations[currentLang][`title-${targetTab}`] || translations[currentLang][`nav-${targetTab}`];
        });
    });

    // تنفيذ أولي للثيم واللغة
    initTheme();
    const defaultLang = localStorage.getItem('lang') || 'ar';
    applyLanguage(defaultLang);
});