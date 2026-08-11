<?php

namespace Modules\Admin\database\seeders;

use Illuminate\Database\Seeder;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\File;
use Illuminate\Support\Str;
use Modules\Admin\Models\AdminMenu;

class AdminMenuSeeder extends Seeder
{
    public function run(): void
    {
        $path = __DIR__.'/menu.json';
        $items = json_decode(File::get($path), true, flags: JSON_THROW_ON_ERROR);

        DB::transaction(function () use ($items): void {
            AdminMenu::query()->withTrashed()->forceDelete();

            foreach ($items as $index => $item) {
                $this->createItem($item, null, $index);
            }
        });

        AdminMenu::clearMenuCache();

        $this->command?->info('Admin menus deleted and seeded again.');
    }

    private function createItem(array $item, ?int $parentId, int $sort): void
    {
        $menu = AdminMenu::query()->create([
            'name' => $item['name'],
            'slug' => $this->uniqueSlug($item['slug'] ?? Str::slug($item['name'])),
            'parent_id' => $parentId,
            'url' => $item['url'] ?? null,
            'icon' => $item['icon'] ?? null,
            'can' => $item['can'] ?? null,
            'sort_order' => $sort,
            'is_active' => $item['is_active'] ?? true,
        ]);

        foreach ($item['children'] ?? [] as $index => $child) {
            $this->createItem($child, (int) $menu->getKey(), $index);
        }
    }

    private function uniqueSlug(string $slug): string
    {
        $base = $slug !== '' ? $slug : 'menu';
        $candidate = $base;
        $suffix = 2;

        while (AdminMenu::query()->where('slug', $candidate)->exists()) {
            $candidate = $base.'-'.$suffix;
            $suffix++;
        }

        return $candidate;
    }
}
